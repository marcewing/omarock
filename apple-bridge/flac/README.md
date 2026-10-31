# libFLAC, for the bridge's stream

The encoder half of reference libFLAC 1.5.0, from xiph/flac's release
`flac-1.5.0.tar.xz` (sha256 `f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920`),
unchanged. It's under the BSD-style Xiph license in `COPYING.Xiph`.

The bridge uses it (`app/Sources/FlacEncoder.swift`) for `limit_min_bitrate`,
which ffmpeg's own FLAC encoder doesn't have. It stops a frame from being only
constant subframes, so digital silence still streams at about 6 KB/s. Near-empty
silence is what made mpd with a stock libFLAC fall far behind the stream (see
xiph/flac#90 and #264).

What's here, as a SwiftPM C target (`Sources/FLAC`):
- `include/FLAC/`: the public headers.
- `libFLAC/`: the sources the stream encoder needs (it links the decoder for its
  verify mode), with their private headers and `include/share/`.
- Left out: Ogg (the bridge writes its own Ogg pages), the x86 and NEON
  intrinsics (`FLAC__NO_ASM`; 48 kHz stereo costs next to nothing without them), the
  metadata file editing, and the tools.

To update: copy the same files from a new release, change the version in
`Package.swift` and here, and check that `swift build` builds it.
