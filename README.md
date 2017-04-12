Validate HLS streams
====================

This script checks a HLS playlist for the following:

- Whether all `.ts` fragments can be downloaded for all quality levels
- Whether all `.ts` fragments have video frames
- Whether all `.ts` fragments start with a keyframe

These are just the issues that we check for. There are other things that can go wrong with a HLS stream.

Note that **we do not actively maintain this script**. You will need to fix any issues yourself.


Setup
-----

- Install `ffmpeg`
- Install `wget`
- Install Ruby 2+
- Clone this repo to get the script


Usage
------

```
ruby validate-hls.rb "http://host/path/playlist.m3u8"
```

This will download, validate and print results for each `.m3u8` and `.ts` URL.

The URL can point to either a playlist of `.ts` files, or to a master playlist of multiple quality playlists.


Credits
-------

Henning Koch ([@triskweline](https://twitter.com/triskweline)) from [makandra](https://makandra.com).
