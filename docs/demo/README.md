# Reproduce the demo

The GIF is a 15-second condensed visualization of a real fixture sync. It is not a recording of wall-clock execution time. The transcript is generated only after assertions pass against actual output files.

From the project root, with the normal runtime dependencies installed:

```bash
COPYBARA_JAR=/path/to/copybara_deploy-v20260907.jar python3 scripts/demo.py
```

This creates temporary source/client repositories, runs the normal sync command, checks that internal agent files are excluded, client-only files survive, the new comment is absent, the feature change remains, and the client branch is not modified. It writes `docs/demo/transcript.json`. No AI or remote repository is used.

To render the GIF on macOS, install Swift command-line tools and FFmpeg, then:

```bash
swift scripts/render-demo.swift docs/demo/transcript.json /tmp/release-sync-frames
ffmpeg -y -framerate 1/3 -i /tmp/release-sync-frames/%02d.png \
  -vf 'split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=bayer' \
  -loop 0 docs/images/demo.gif
```

The demo renderer is a documentation-only utility; the sync tool does not depend on Swift or FFmpeg.
