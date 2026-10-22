# FFmpeg Windows x64 shared libraries

Source: BtbN/FFmpeg-Builds, LGPL shared FFmpeg 9.0 branch build.
Archive: https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n9.0-latest-win64-lgpl-shared-9.0.zip
Archive SHA-256: `339a1011a19ca1a4be9b492ec54cbf1f387722c70245e873417f9d0fab483799`
Archive entry timestamps: 2026-10-22 12:45. The upstream `latest` URL is mutable;
the hash identifies the downloaded artifact, not an independent authenticity check.

The three `.lib` files are upstream Windows import libraries, not static codecs.
Ship all four DLLs beside the executable: avcodec also depends on swresample.
`objdump -p` confirms the remaining imported DLLs are Windows system libraries.
The build uses the Windows Universal CRT.

`LICENSE.txt` is the upstream LGPL license. Upstream build scripts and source
retrieval information: https://github.com/BtbN/FFmpeg-Builds . Preserve the
matching source/build information and satisfy applicable LGPL redistribution
requirements before distributing a release; the license file alone is not a
complete compliance package.

The Odin bindings declare public struct prefixes from this archive's headers.
FFmpeg must allocate these objects; the incomplete Odin types are pointer-only.
Application packaging is handled separately.
