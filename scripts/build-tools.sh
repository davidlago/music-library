#!/usr/bin/env bash
# Builds the ffmpeg, ffprobe and fpcalc that go inside MusicLibrary.app, so the app needs nothing from Homebrew.
# Output: build/tools/{ffmpeg,ffprobe,fpcalc} and build/tools/Licenses. Already-built tools are reused until this
# script changes.
#
#   UNIVERSAL=1   build for both Apple Silicon and Intel (default: this Mac's architecture only)
#
# FFmpeg is configured as LGPL (no --enable-gpl, no external libraries) with only what the app runs: reading tags
# (ffprobe), rewriting mp3/flac/m4a tags and covers (stream copy), extracting and converting cover images to JPEG,
# and encoding CD audio (AIFF) to FLAC. fpcalc (Chromaprint) links that same FFmpeg and Accelerate's vDSP for its FFT.
# Building needs Xcode or the Command Line Tools, and cmake (`brew install cmake`; GitHub's macOS runners have it).
set -euo pipefail

cd "$(dirname "$0")/.."

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
CHROMAPRINT_VERSION=1.6.1
CHROMAPRINT_SHA256=3368805af0ee47b9df74df10b5001a44569e01df2844dab520031720dde9ad23
MIN_MACOS=14.0

HOST_ARCH="$(uname -m)"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$HOST_ARCH"); fi

OUT=build/tools
SRC=build/tools-src
WORK=build/tools-work

# Skip the build when the tools were made by this exact script for the same architectures.
STAMP="$(shasum -a 256 "$0" | cut -d' ' -f1) ${ARCHS[*]}"
if [[ -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" ]]; then
    echo "Tools are up to date in $OUT"
    exit 0
fi

command -v cmake >/dev/null || { echo "error: cmake is needed to build fpcalc (brew install cmake)" >&2; exit 1; }

fetch() { # url sha256 file
    local url="$1" sum="$2" file="$SRC/$3"
    mkdir -p "$SRC"
    if [[ ! -f "$file" ]] || ! echo "$sum  $file" | shasum -a 256 -c --status; then
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    echo "$sum  $file" | shasum -a 256 -c --status || { echo "error: checksum mismatch for $file" >&2; exit 1; }
}

fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" "ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "https://github.com/acoustid/chromaprint/releases/download/v$CHROMAPRINT_VERSION/chromaprint-$CHROMAPRINT_VERSION.tar.gz" \
    "$CHROMAPRINT_SHA256" "chromaprint-$CHROMAPRINT_VERSION.tar.gz"

join() { local IFS=,; echo "$*"; }

DEMUXERS=(aac ac3 aiff eac3 flac mov mp3 ogg wav w64 asf gif image2 image2pipe
    image_bmp_pipe image_gif_pipe image_jpeg_pipe image_png_pipe image_tiff_pipe image_webp_pipe)
MUXERS=(flac mp3 ipod mp4 mov image2 image2pipe pcm_s16le)
DECODERS=(aac alac flac mp3 mp3float mp2 mp2float vorbis opus wmav1 wmav2 ac3 eac3
    pcm_s8 pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be
    pcm_f32le pcm_f32be pcm_f64le pcm_f64be pcm_alaw pcm_mulaw
    mjpeg png webp gif bmp tiff)
ENCODERS=(flac mjpeg pcm_s16le)
PARSERS=(aac ac3 flac mpegaudio opus vorbis mjpeg png webp gif bmp)
BSFS=(aac_adtstoasc)
FILTERS=(abuffer abuffersink buffer buffersink aformat anull aresample format null scale transpose hflip vflip)
PROTOCOLS=(file pipe)

JOBS="$(sysctl -n hw.ncpu)"

for arch in "${ARCHS[@]}"; do
    dir="$WORK/$arch"
    prefix="$dir/prefix"
    rm -rf "$dir"
    mkdir -p "$dir"

    echo "==> FFmpeg $FFMPEG_VERSION ($arch)"
    tar -xJf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$dir"
    cross=()
    # Intel builds skip the hand-written x86 assembly (it needs nasm); it matters little for audio.
    if [[ "$arch" == x86_64 ]]; then cross+=(--disable-x86asm); fi
    if [[ "$arch" != "$HOST_ARCH" ]]; then cross+=(--enable-cross-compile); fi
    (
        cd "$dir/ffmpeg-$FFMPEG_VERSION"
        ./configure --prefix="$PWD/../prefix" \
            --arch="$arch" --target-os=darwin ${cross[@]+"${cross[@]}"} \
            --cc="clang -arch $arch" \
            --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
            --enable-static --disable-shared --disable-autodetect --enable-zlib \
            --disable-debug --disable-doc --disable-network --disable-ffplay --disable-avdevice \
            --disable-everything \
            --enable-demuxer="$(join "${DEMUXERS[@]}")" --enable-muxer="$(join "${MUXERS[@]}")" \
            --enable-decoder="$(join "${DECODERS[@]}")" --enable-encoder="$(join "${ENCODERS[@]}")" \
            --enable-parser="$(join "${PARSERS[@]}")" --enable-bsf="$(join "${BSFS[@]}")" \
            --enable-filter="$(join "${FILTERS[@]}")" --enable-protocol="$(join "${PROTOCOLS[@]}")" \
            > ../configure.log
        make -j"$JOBS" > ../make.log 2>&1
        make install > /dev/null
    )

    echo "==> Chromaprint $CHROMAPRINT_VERSION ($arch)"
    tar -xzf "$SRC/chromaprint-$CHROMAPRINT_VERSION.tar.gz" -C "$dir"
    abs_prefix="$(cd "$prefix" && pwd)"
    lib() { echo "-DFFMPEG_LIB$1_LIBRARIES=$abs_prefix/lib/lib$2.a" "-DFFMPEG_LIB$1_INCLUDE_DIRS=$abs_prefix/include"; }
    # Point Chromaprint at this FFmpeg explicitly so it never picks up a Homebrew one.
    cmake -S "$dir/chromaprint-$CHROMAPRINT_VERSION" -B "$dir/chromaprint-build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TOOLS=ON -DBUILD_TESTS=OFF -DFFT_LIB=vdsp \
        -DFFMPEG_ROOT="$abs_prefix" $(lib AVFORMAT avformat) $(lib AVCODEC avcodec) $(lib AVUTIL avutil) \
        $(lib SWRESAMPLE swresample) > "$dir/chromaprint-cmake.log"
    cmake --build "$dir/chromaprint-build" --target fpcalc -j"$JOBS" > "$dir/chromaprint-build.log" 2>&1
done

rm -rf "$OUT"
mkdir -p "$OUT/Licenses"
for tool in ffmpeg ffprobe fpcalc; do
    inputs=()
    for arch in "${ARCHS[@]}"; do
        if [[ "$tool" == fpcalc ]]; then inputs+=("$WORK/$arch/chromaprint-build/src/cmd/fpcalc")
        else inputs+=("$WORK/$arch/prefix/bin/$tool"); fi
    done
    lipo -create "${inputs[@]}" -output "$OUT/$tool"
    strip -x "$OUT/$tool" 2>/dev/null || true
    # Nothing outside the system may be linked in.
    if otool -L "$OUT/$tool" | grep -E '^\s' | grep -vE '^\s+(/usr/lib/|/System/Library/)'; then
        echo "error: $tool links a library outside the system" >&2; exit 1
    fi
done

first="$WORK/${ARCHS[0]}"
cp "$first/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$OUT/Licenses/FFmpeg-LGPL-2.1.txt"
cp "$first/chromaprint-$CHROMAPRINT_VERSION/LICENSE.md" "$OUT/Licenses/Chromaprint-LICENSE.md"
cat > "$OUT/Licenses/README.txt" <<EOF
Music Library includes these programs, built unmodified from their source releases by scripts/build-tools.sh
(https://github.com/davidlago/music-library/blob/main/scripts/build-tools.sh):

- ffmpeg and ffprobe from FFmpeg $FFMPEG_VERSION (https://ffmpeg.org), licensed under the GNU Lesser General Public
  License version 2.1 or later (FFmpeg-LGPL-2.1.txt). Source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
- fpcalc from Chromaprint $CHROMAPRINT_VERSION (https://acoustid.org/chromaprint), MIT and LGPL 2.1
  (Chromaprint-LICENSE.md). Source: https://github.com/acoustid/chromaprint/releases/tag/v$CHROMAPRINT_VERSION

FFmpeg configuration: $(sed -n 's/^FFMPEG_CONFIGURATION="\(.*\)"$/\1/p' "$first/ffmpeg-$FFMPEG_VERSION/config.h" 2>/dev/null | head -1)
EOF

echo "$STAMP" > "$OUT/.stamp"
for tool in ffmpeg ffprobe fpcalc; do echo "Built $OUT/$tool ($(lipo -archs "$OUT/$tool"), $(du -h "$OUT/$tool" | cut -f1))"; done
