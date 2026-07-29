#!/bin/bash
# Reproducibly build an Apple Silicon, static, LGPL/BSD FFmpeg/ffprobe bundle for macOS.
#
# Usage: Scripts/build-media-tools.sh [--work-dir PATH] [--output-dir PATH]
#        [--signing-identity IDENTITY] [--jobs N] [--keep-work]
#
# The default output is Sources/FileConvertApp/Resources/MediaTools.  The script
# only accepts the pinned sources below, verifies every archive SHA-256 before
# extraction, and replaces the resource manifest only after all artifact checks
# pass.  MEDIA_TOOLS_SIGNING_IDENTITY may also provide a release signing identity;
# empty identity means deterministic local ad-hoc signing.
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT/.build/media-tools"
OUTPUT_DIR="$ROOT/Sources/FileConvertApp/Resources/MediaTools"
SIGNING_IDENTITY="${MEDIA_TOOLS_SIGNING_IDENTITY:-}"
JOBS="$(sysctl -n hw.ncpu)"
KEEP_WORK=0

usage() { sed -n '2,11p' "$0"; }
die() { printf 'build-media-tools.sh: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --work-dir) WORK_DIR=${2:?missing value}; shift 2 ;;
    --output-dir) OUTPUT_DIR=${2:?missing value}; shift 2 ;;
    --signing-identity) SIGNING_IDENTITY=${2:?missing value}; shift 2 ;;
    --jobs) JOBS=${2:?missing value}; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$(uname -s)" == Darwin ]] || die "a macOS host is required"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
for tool in curl shasum tar make clang codesign otool xcrun python3; do command -v "$tool" >/dev/null || die "missing required tool: $tool"; done
[[ "$(uname -m)" == arm64 ]] || die "an Apple Silicon build host is required"

# name|version|url|sha256|license|archive-basename
SOURCES=(
  'ffmpeg|8.1.2|https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz|464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c|LGPL-2.1-or-later|ffmpeg-8.1.2.tar.xz'
  'lame|4.0|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb|LGPL-2.0-or-later|lame-4.0.tar.gz'
  'libogg|1.3.6|https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz|83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638|BSD-3-Clause|libogg-1.3.6.tar.gz'
  'libvorbis|1.3.7|https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.xz|b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b|BSD-3-Clause|libvorbis-1.3.7.tar.xz'
  'opus|1.6.1|https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1|BSD-3-Clause|opus-1.6.1.tar.gz'
  'libvpx|1.16.0|https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz|7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c|BSD-3-Clause|libvpx-1.16.0.tar.gz'
)

DOWNLOADS="$WORK_DIR/downloads"; SOURCES_DIR="$WORK_DIR/sources"; BUILD_DIR="$WORK_DIR/build"
mkdir -p "$DOWNLOADS" "$SOURCES_DIR" "$BUILD_DIR"
if (( ! KEEP_WORK )); then trap 'rm -rf "$WORK_DIR"' EXIT; fi
for item in "${SOURCES[@]}"; do
  IFS='|' read -r name version url expected_sha license archive <<<"$item"
  archive_path="$DOWNLOADS/$archive"
  [[ -f "$archive_path" ]] || curl --fail --location --retry 3 --proto '=https' --tlsv1.2 --output "$archive_path" "$url"
  actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || die "SHA-256 mismatch for $name"
  source_path="$SOURCES_DIR/$name-$version"
  if [[ ! -d "$source_path" ]]; then
    tar -xf "$archive_path" -C "$SOURCES_DIR"
    extracted="$(tar -tf "$archive_path" | awk -F/ 'NF {print $1; exit}')"
    [[ -n "$extracted" && -d "$SOURCES_DIR/$extracted" ]] || die "unexpected archive layout: $archive"
    [[ "$SOURCES_DIR/$extracted" == "$source_path" ]] || mv "$SOURCES_DIR/$extracted" "$source_path"
  fi
done

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
DARWIN_MAJOR="$(uname -r | cut -d. -f1)"
COMMON_CFLAGS="-isysroot $SDKROOT -mmacosx-version-min=14.0 -fPIC"
COMMON_LDFLAGS="-isysroot $SDKROOT -mmacosx-version-min=14.0"

build_arch() {
  local arch=$1
  local prefix="$BUILD_DIR/$arch/prefix"
  local pkg="$prefix/lib/pkgconfig"
  local ffmpeg_arch="$arch"
  [[ "$arch" == arm64 ]] && ffmpeg_arch=aarch64
  local cflags="$COMMON_CFLAGS -arch $arch" ldflags="$COMMON_LDFLAGS -arch $arch"
  mkdir -p "$prefix" "$BUILD_DIR/$arch/libogg" "$BUILD_DIR/$arch/libvorbis" "$BUILD_DIR/$arch/opus" "$BUILD_DIR/$arch/lame"
  export CC=clang CXX=clang++ AR=ar RANLIB=ranlib NM=nm CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags" PKG_CONFIG_PATH="$pkg"
  (cd "$BUILD_DIR/$arch/libogg" && "$SOURCES_DIR/libogg-1.3.6/configure" --host="$ffmpeg_arch-apple-darwin" --prefix="$prefix" --disable-shared --enable-static && make -j"$JOBS" install)
  (cd "$BUILD_DIR/$arch/libvorbis" && "$SOURCES_DIR/libvorbis-1.3.7/configure" --host="$ffmpeg_arch-apple-darwin" --prefix="$prefix" --disable-shared --enable-static --with-ogg="$prefix" && make -j"$JOBS" noinst_PROGRAMS= install)
  (cd "$BUILD_DIR/$arch/opus" && "$SOURCES_DIR/opus-1.6.1/configure" --host="$ffmpeg_arch-apple-darwin" --prefix="$prefix" --disable-shared --enable-static --disable-doc && make -j"$JOBS" install)
  (cd "$BUILD_DIR/$arch/lame" && "$SOURCES_DIR/lame-4.0/configure" --host="$ffmpeg_arch-apple-darwin" --prefix="$prefix" --disable-shared --enable-static --disable-decoder --disable-frontend && make -j"$JOBS" install)
  cp "$pkg/lame.pc" "$pkg/libmp3lame.pc"
  mkdir -p "$BUILD_DIR/$arch/libvpx"
  (cd "$BUILD_DIR/$arch/libvpx" && "$SOURCES_DIR/libvpx-1.16.0/configure" --prefix="$prefix" --target="$arch-darwin$DARWIN_MAJOR-gcc" --disable-shared --enable-static --disable-examples --disable-unit-tests --enable-vp9-highbitdepth && make -j"$JOBS" install)
  mkdir -p "$BUILD_DIR/$arch/ffmpeg"
  (cd "$BUILD_DIR/$arch/ffmpeg" && "$SOURCES_DIR/ffmpeg-8.1.2/configure" \
    --prefix="$prefix" --arch="$ffmpeg_arch" --target-os=darwin --cc=clang --cxx=clang++ --ar=ar --ranlib=ranlib --nm=nm \
    --pkg-config-flags=--static --disable-autodetect --disable-debug --disable-doc --disable-everything --disable-ffplay --disable-network --disable-programs --disable-shared --enable-static \
    --enable-ffmpeg --enable-ffprobe --enable-avcodec --enable-avfilter --enable-avformat --enable-avutil --enable-swresample --enable-swscale --enable-protocol=file \
    --enable-indev=lavfi --enable-filter=anullsrc,aresample,format,scale,sine,testsrc2 \
    --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx \
    --enable-decoder=aac,alac,flac,h264,hevc,mp3float,mpeg4,opus,pcm_s16be,pcm_s16le,pcm_s24le,pcm_u8,vorbis,vp8,vp9,wrapped_avframe \
    --enable-encoder=aac,flac,libmp3lame,libopus,libvorbis,libvpx_vp8,libvpx_vp9,mpeg4,pcm_s16be,pcm_s16le \
    --enable-demuxer=aac,aiff,flac,matroska,mov,mp3,mpegts,ogg,wav \
    --enable-muxer=adts,aiff,flac,ipod,matroska,mov,mp3,mp4,null,ogg,opus,wav,webm \
    --enable-parser=aac,h264,hevc,mpegaudio,mpeg4video,opus,vp8,vp9 \
    --extra-cflags="$cflags -I$prefix/include" --extra-ldflags="$ldflags -L$prefix/lib" \
    --extra-libs='-lbz2 -lz' && make -j"$JOBS")
}
build_arch arm64

STAGING="$WORK_DIR/staging"; rm -rf "$STAGING"; mkdir -p "$STAGING/LICENSES"
install -m 755 "$BUILD_DIR/arm64/ffmpeg/ffmpeg" "$STAGING/ffmpeg"
install -m 755 "$BUILD_DIR/arm64/ffmpeg/ffprobe" "$STAGING/ffprobe"
if [[ -n "$SIGNING_IDENTITY" ]]; then codesign --force --sign "$SIGNING_IDENTITY" "$STAGING/ffmpeg" "$STAGING/ffprobe"; else codesign --force --sign - "$STAGING/ffmpeg" "$STAGING/ffprobe"; fi

# Materialize exact notices and their hashes; this is part of the signed source lock.
for item in "${SOURCES[@]}"; do
  IFS='|' read -r name version url expected_sha license archive <<<"$item"
  license_file="$(find "$SOURCES_DIR/$name-$version" -maxdepth 2 -type f \( -iname 'copying*' -o -iname 'license*' \) | sort | head -n 1)"
  [[ -n "$license_file" ]] || die "no license notice found for $name"
  cp "$license_file" "$STAGING/LICENSES/$name.txt"
done
python3 - "$STAGING/source-lock.json" "$STAGING/LICENSES" "${SOURCES[@]}" <<'PY'
import hashlib, json, pathlib, sys
output, notices, *rows = sys.argv[1:]
sources = []
licenses = []
for row in rows:
    name, version, url, digest, license_name, _archive = row.split("|")
    notice = pathlib.Path(notices, f"{name}.txt")
    notice_hash = hashlib.sha256(notice.read_bytes()).hexdigest()
    sources.append({"name": name, "version": version, "url": url, "sha256": digest, "license": license_name})
    licenses.append({"name": name, "license": license_name, "source": f"LICENSES/{name}.txt", "sha256": notice_hash})
pathlib.Path(output).write_text(json.dumps({"sources": sources, "licenses": licenses}, indent=2, sort_keys=True) + "\n")
PY
MEDIA_TOOLS_SIGNING_IDENTITY="$SIGNING_IDENTITY" "$ROOT/Scripts/generate-media-manifest.py" --ffmpeg "$STAGING/ffmpeg" --ffprobe "$STAGING/ffprobe" --source-lock "$STAGING/source-lock.json" --output "$STAGING/manifest.json"
rm "$STAGING/source-lock.json"
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/LICENSES" "$OUTPUT_DIR/ffmpeg" "$OUTPUT_DIR/ffprobe"
cp -R "$STAGING/LICENSES" "$OUTPUT_DIR/LICENSES"
install -m 755 "$STAGING/ffmpeg" "$STAGING/ffprobe" "$OUTPUT_DIR/"
install -m 644 "$STAGING/manifest.json" "$OUTPUT_DIR/manifest.json"
printf 'Built pinned Apple Silicon FFmpeg tools in %s\n' "$OUTPUT_DIR"
