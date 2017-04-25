#!/usr/bin/env ruby


module ValidateHls

  class Error < StandardError; end
  class CommandFailed < Error; end
  class DownloadFailed < CommandFailed; end
  class Invalid < Error; end
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

    def initialize(url)
      @url = url
    end

    attr_reader :url

    private

    def filename
      File.basename(@url)
    end

    def local_path
      File.join(temp_dir, filename)
    end

    def download
      within_temp_dir do
        begin
          run 'wget', url
        rescue DownloadFailed
          puts "Download failed ✘"
        end
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

    def validate
      print "Validating playlist #{url}: "
      download
      parse_urls

      if playlist_urls.size == 0 && fragment_urls.size == 0
        puts "No URLs found in playlist ✘"
      else
        puts 'Has URLs ✔'
        playlist_urls.each do |playlist_url|
          playlist = Playlist.new(playlist_url)
          playlist.validate
        end
        fragment_urls.each do |fragment_url|
          fragment = Fragment.new(fragment_url)
          fragment.validate
        end
      end
    end

    private

    attr_reader :playlist_urls, :fragment_urls

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
    end

  end

  class Fragment < Resource

    def validate
      print "Validating fragment #{url}: "
      download

      begin
        ffprobe_out = run('ffprobe', '-select_streams', 'v:0', '-show_frames', local_path)
        keyframe_lines = ffprobe_out.scan(/key_frame=\d/)

        if keyframe_lines.size == 0
          puts "No frames found ✘"
        elsif !keyframe_lines.include?('key_frame=1')
          puts "No keyframes found in any frame ✘"
        elsif keyframe_lines[0] != 'key_frame=1'
          puts "Keyframe is not the first frame ✘"
        else
          puts 'Keyframe is first frame ✔'
        end

      rescue CommandFailed => e
        puts "Keyframe analysis failed ✘"
      end

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

  class Validator

    def initialize(url)
      @url = url
    end

    def run
      check_url
      check_dependencies
      validate
      print_banner
      print_result
      puts "Stream passed validation"
      exit 0
    rescue Error => e
      puts e.message
      exit 1
    end

    private

    def check_dependencies
      Dependencies.check
    end

    def check_url
      @url.is_a?(String) && @url.size > 0 or raise Error, "Must give URL to .m3u8 playlist as first argument"
    end

    def print_banner
      puts <<~BANNER

      BANNER
      puts "HLS Stream verifier"
      puts "-------------------"
      puts
      puts
      puts
      puts "This script checks:"
      puts "- Whether all .ts fragments can be downloaded"
      puts "- Whether all .ts fragments have video frames"
      puts "- Whether all .ts fragments start with a keyframe"
      puts
    end

  end

end

playlist_url = ARGV[0]
validator = ValidateHls::Validator.new(playlist_url)
validator.run
