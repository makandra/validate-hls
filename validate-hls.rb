#!/usr/bin/env ruby


module ValidateHls

  class Error < StandardError; end
  class CommandFailed < Error; end
  class DownloadFailed < Error; end
  class Invalid < Error; end
  class InvalidChild < Error; end
  class MissingDependency < Error; end

  module Util
    require 'open3'

    def run(command, *args)
      stdout_str, error_str, status = Open3.capture3(command, *args)
      if status.success?
        stdout_str
      else
        raise CommandFailed, "Error running #{command} #{args.inspect}:\n\n#{error_str}"
      end
    end

    def download(url)
      run 'wget', url
    rescue CommandFailed => e
      raise DownloadFailed, e.message
    end

  end

  module WithinTempDir
    require 'tmpdir'

    def temp_dir
      @temp_dir ||= Dir.mktmpdir
    end

    def within_temp_dir(&block)
      Dir.chdir(temp_dir, &block)
    end

  end

  class Resource
    include WithinTempDir
    include Util

    def initialize(url, log)
      @url = url
      @log = log
    end

    attr_reader :url, :log

    def to_s
      name = self.class.name.split('::').last
      "#{name}(#{url})"
    end

    private

    def filename
      File.basename(@url)
    end

    def local_path
      File.join(temp_dir, filename)
    end

    def download
      within_temp_dir do
        run 'wget', url
        log.positive_message('Downloadable with 200 OK')
      end
    end

    def data
      within_temp_dir do
        File.read(filename)
      end
    end

    def parent_url
      File.dirname(url)
    end

    def full_url(url_or_path)
      if url_or_path.include?('://')
        url_or_path
      else
        File.join(parent_url, url_or_path)
      end
    end

  end

  class Playlist < Resource

    def validate!
      log.subject_started(self)
      download
      parse_urls
      validate_children
      log.subject_passed(self)
    rescue Error => e
      log.negative_message(e.message)
      log.subject_failed(self)
      raise Invalid, e.message
    end

    private

    attr_reader :playlist_urls, :fragment_urls

    def validate_children
      child_error = false
      playlist_urls.each do |playlist_url|
        begin
          playlist = Playlist.new(playlist_url, log)
          playlist.validate!
        rescue Error => e
          child_error = true
        end
      end
      fragment_urls.each do |fragment_url|
        begin
          fragment = Fragment.new(fragment_url, log)
          fragment.validate!
        rescue Error => e
          child_error = true
        end
      end

      if child_error
        # e.message was already printed by child, so just explain that we're failing
        # because of a child failure
        raise Invalid, 'Error in child resource'
      end
    end

    def parse_urls
      @fragment_urls = []
      @playlist_urls = []
      lines = data.split(/\n/)
      lines.each do |line|
        line = line.strip
        if line.end_with?('.ts')
          @fragment_urls << full_url(line)
        end
        if line.end_with?('.m3u8')
          @playlist_urls << full_url(line)
        end
      end

      if playlist_urls.size == 0 && fragment_urls.size == 0
        raise Invalid, 'No URLs found in playlist'
      end

    end

  end

  class Fragment < Resource

    def validate!
      log.subject_started(self)
      download
      validate_frames
      log.subject_passed(self)
    rescue Error => e
      log.negative_message(e.message)
      log.subject_failed(self)
      raise Invalid, e.message
    end

    private

    def validate_frames
      ffprobe_out = run('ffprobe', '-select_streams', 'v:0', '-show_frames', local_path)
      keyframe_lines = ffprobe_out.scan(/key_frame=\d/)

      if keyframe_lines.size == 0
        raise Invalid, "No frames found"
      elsif !keyframe_lines.include?('key_frame=1')
        raise Invalid, "No keyframes found in any frame"
      elsif keyframe_lines[0] != 'key_frame=1'
        raise Invalid, "Keyframe is not the first frame"
      else
        log.positive_message 'Keyframe is first frame'
      end
    rescue CommandFailed => e
      raise Invalid, "Keyframe analysis failed: #{e.message}"
    end

  end

  module Dependencies
    include Util
    extend self

    def check
      # Check dependencies
      begin
        run 'wget', '--help'
      rescue CommandFailed
        raise MissingDependency, "No wget installed"
      end

      begin
        run 'ffprobe', '-h'
      rescue CommandFailed
        raise MissingDependency, "No ffprobe installed"
      end
    end

  end

  class Log

    COLOR_HEAD = "\e[44;97m"
    COLOR_WARNING = "\e[33m"
    COLOR_POSITIVE = "\e[32m"
    COLOR_NEGATIVE = "\e[31m"
    COLOR_RESET = "\e[0m"

    def initialize
      @target = STDOUT
      @indent_level = 0
      @success = true
    end

    def subject_started(subject)
      puts "Validating: #{subject}"
      @indent_level += 1
    end

    def subject_passed(subject)
      # positive_message "Passed"
      @indent_level -= 1
    end

    def subject_failed(subject)
      # negative_message "Failed"
      @indent_level -= 1
    end

    def head(message)
      puts message, COLOR_HEAD
    end

    def positive_message(message)
      puts "✔ #{message}", COLOR_POSITIVE
    end

    def negative_message(message)
      @success = false
      puts "✘ #{message}", COLOR_NEGATIVE
    end

    def puts(string = '', color = nil)
      lines = string.strip.split(/\n/)
      lines = [''] if lines.size == 0
      indent_string = "| " * @indent_level
      lines.each do |line|
        @target.print indent_string
        @target.print color if color # don't colorize background for the indentation
        @target.print line
        @target.print COLOR_RESET if color
        @target.print "\n"
      end
    end

    def success?
      @success
    end

  end

  class PlaylistSet

    def initialize(urls, log)
      @urls = urls
      @log = log
    end

    attr_reader :urls, :log

    def validate!
      log.subject_started(self)
      validate_children
      log.subject_passed(self)
    rescue Error => e
      log.negative_message(e.message)
      log.subject_failed(self)
      raise Invalid, e.message
    end

    def to_s
      "Set of #{urls.size} URL(s)"
    end

    private

    def validate_children
      child_error = false
      @urls.each do |url|
        begin
          playlist = Playlist.new(url, @log)
          playlist.validate!
        rescue Error => e
          child_error = true
        end
      end

      if child_error
        # e.message was already printed by child, so just explain that we're failing
        # because of a child failure
        raise Invalid, 'One or more playlists had errors'
      end
    end

  end

  class Validator

    def initialize(urls)
      @urls = Array[*urls] # Array.wrap without ActiveSupport
      @log = Log.new
    end

    attr_reader :urls, :log

    def run
      print_banner
      check_urls
      check_dependencies
      validate!
      error_code = @log.success? ? 1 : 0
      exit error_code
    rescue Error => e
      log.negative_message "Validation failed: #{e.message}"
      exit 1
    end

    private

    def validate!
      set = PlaylistSet.new(urls, log)
      set.validate!
    end

    def check_dependencies
      Dependencies.check
    end

    def check_urls
      unless @urls && @urls.size > 0
        raise Error, "Must pass one or more URLs to .m3u8 playlists as arguments"
      end
    end

    def print_banner
      log.puts
      log.head "validate-hls"
      log.puts
    end

  end

end

validator = ValidateHls::Validator.new(ARGV)
validator.run
