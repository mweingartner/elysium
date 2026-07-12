#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXECUTABLE=""
OUTPUT=""
MANIFEST=""
EXPECTED_HASH=""
CAPTURE_DIR=""

die() { echo "package-app failed: $*" >&2; exit 1; }
cleanup() {
    [ -z "$CAPTURE_DIR" ] || rm -rf -- "$CAPTURE_DIR"
}
trap cleanup EXIT INT TERM
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
canonical_file() {
    local directory base
    directory="$(cd "$(dirname "$1")" && pwd -P)" || return 1
    base="$(basename "$1")"
    printf '%s/%s\n' "$directory" "$base"
}

# Fixed raw-channel parser used by both production capture and table-driven fixtures. It opens every
# channel O_NOFOLLOW, validates bytes before UTF-8 decode, never merges descriptors, and writes only
# the normalized requirement to a new private file.
CODESIGN_CHANNEL_PERL='use strict; use warnings; use bytes;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Fcntl qw(:DEFAULT O_NOFOLLOW);
use IO::Handle;
use POSIX ();

sub read_private {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "capture open";
    my @st = stat($fh);
    die "capture identity" unless @st && (($st[2] & 0170000) == 0100000) &&
        (($st[2] & 0777) == 0600) && $st[3] == 1;
    binmode($fh);
    local $/;
    my $data = <$fh>;
    defined($data) or die "capture read";
    close($fh) or die "capture close";
    return $data;
}

sub envelope {
    my ($data, $limit) = @_;
    die "capture size" unless length($data) > 0 && length($data) <= $limit;
    die "capture newline" unless substr($data, -1, 1) eq "\n" &&
        (($data =~ tr/\n//) == 1);
    my $body = substr($data, 0, -1);
    for my $byte (unpack("C*", $body)) {
        die "capture control" if $byte < 0x20 || $byte == 0x7f;
    }
    eval { decode("UTF-8", $data, FB_CROAK | LEAVE_SRC) };
    die "capture utf8" if $@;
}

sub parse_channels {
    my ($status, $stdout_path, $stderr_path, $expected) = @_;
    die "codesign status" unless $status =~ /\A[0-9]+\z/ && int($status) == 0;
    my $stdout = read_private($stdout_path);
    my $stderr = read_private($stderr_path);
    envelope($stdout, 4128);
    envelope($stderr, 8192);
    die "executable channel" unless $stderr eq "Executable=$expected\n";
    my $decorated = "# designated => ";
    my $legacy = "designated => ";
    my $prefix;
    if (index($stdout, $decorated) == 0) { $prefix = $decorated; }
    elsif (index($stdout, $legacy) == 0) { $prefix = $legacy; }
    else { die "requirement prefix"; }
    my $payload = substr($stdout, length($prefix), length($stdout) - length($prefix) - 1);
    die "requirement size" unless length($payload) > 0 && length($payload) <= 4096;
    die "requirement comment" if index($payload, "#") >= 0;
    for my $byte (unpack("C*", $payload)) {
        die "requirement control" if $byte < 0x20 || $byte == 0x7f;
    }
    my $value = eval { decode("UTF-8", $payload, FB_CROAK | LEAVE_SRC) };
    die "requirement utf8" if $@;
    die "requirement whitespace" if $value =~ /\A\s|\s\z/;
    return $payload;
}

sub write_normalized {
    my ($path, $payload) = @_;
    sysopen(my $fh, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or
        die "normalized open";
    binmode($fh);
    print {$fh} $payload, "\n" or die "normalized write";
    $fh->sync or die "normalized sync";
    close($fh) or die "normalized close";
}

my $mode = shift(@ARGV) // "";
if ($mode eq "fixture") {
    die "fixture args" unless @ARGV == 5;
    my ($status, $stdout_path, $stderr_path, $expected, $normalized) = @ARGV;
    write_normalized($normalized,
        parse_channels($status, $stdout_path, $stderr_path, $expected));
    exit 0;
}
die "capture args" unless $mode eq "capture" && @ARGV == 4;
my ($bundle, $stdout_path, $stderr_path, $normalized) = @ARGV;
my $expected = "$bundle/Contents/MacOS/Pebble";
sysopen(my $stdout, $stdout_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or
    die "stdout open";
sysopen(my $stderr, $stderr_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or
    die "stderr open";
binmode($stdout); binmode($stderr);
my $pid = fork();
defined($pid) or die "codesign fork";
if ($pid == 0) {
    open(STDOUT, ">&", fileno($stdout)) or POSIX::_exit(126);
    open(STDERR, ">&", fileno($stderr)) or POSIX::_exit(126);
    exec {"/usr/bin/codesign"} "/usr/bin/codesign", "-d", "-r-", $bundle or
        POSIX::_exit(127);
}
waitpid($pid, 0) == $pid or die "codesign wait";
my $status = $? >> 8;
$stdout->sync or die "stdout sync";
$stderr->sync or die "stderr sync";
close($stdout) or die "stdout close";
close($stderr) or die "stderr close";
write_normalized($normalized,
    parse_channels($status, $stdout_path, $stderr_path, $expected));'

if [ "${1:-}" = "--validate-codesign-fixture" ]; then
    [ "$#" -eq 6 ] || die "codesign fixture arguments invalid"
    exec /usr/bin/perl -e "$CODESIGN_CHANNEL_PERL" -- fixture "$2" "$3" "$4" "$5" "$6"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --executable) EXECUTABLE="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --expected-hash) EXPECTED_HASH="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$EXECUTABLE" ] && [ -n "$OUTPUT" ] && [ -n "$MANIFEST" ] || \
    die "usage: package-app.sh --executable PATH --output APP --manifest PATH [--expected-hash SHA256]"
[ -f "$EXECUTABLE" ] && [ ! -L "$EXECUTABLE" ] || die "release executable must be a regular non-symlink file"
EXECUTABLE="$(canonical_file "$EXECUTABLE")" || die "cannot resolve release executable"
INPUT_HASH="$(sha256 "$EXECUTABLE")"
[ -z "$EXPECTED_HASH" ] || [ "$INPUT_HASH" = "$EXPECTED_HASH" ] || die "release executable hash changed"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$ROOT/packaging/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/packaging/AppIcon.icns" "$OUTPUT/Contents/Resources/"
cp "$ROOT/packaging/logo.png" "$OUTPUT/Contents/Resources/"
cp "$ROOT/packaging/title-bg.png" "$OUTPUT/Contents/Resources/"
for asset in "$ROOT"/packaging/*.zip "$ROOT"/packaging/FAITHFUL-LICENSE.txt; do
    [ ! -e "$asset" ] || cp "$asset" "$OUTPUT/Contents/Resources/"
done
cp "$EXECUTABLE" "$OUTPUT/Contents/MacOS/Pebble"
STAGED="$OUTPUT/Contents/MacOS/Pebble"
[ -f "$STAGED" ] && [ ! -L "$STAGED" ] || die "staged executable is not a regular file"
cmp -s "$EXECUTABLE" "$STAGED" || die "staged executable differs before signing"
STAGED_PRE_HASH="$(sha256 "$STAGED")"
[ "$INPUT_HASH" = "$STAGED_PRE_HASH" ] || die "pre-sign hashes differ"

/usr/bin/codesign --force --sign - --identifier com.briangao.pebble "$OUTPUT" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$OUTPUT" >/dev/null 2>&1 || die "strict signature verification failed"
DETAILS="$(/usr/bin/codesign -d --verbose=4 "$OUTPUT" 2>&1)"
BUNDLE_ID="$(printf '%s\n' "$DETAILS" | awk -F= '/^Identifier=/{print $2; exit}')"
CDHASH="$(printf '%s\n' "$DETAILS" | awk -F= '/^CDHash=/{print $2; exit}')"
[ "$BUNDLE_ID" = "com.briangao.pebble" ] || die "unexpected bundle identifier"
[ -n "$CDHASH" ] || die "missing CDHash"
case "$DETAILS" in
    *"Sealed Resources version="*) ;;
    *) die "missing sealed-resource report" ;;
esac
POST_HASH="$(sha256 "$STAGED")"
OUTPUT_CANON="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
STAGED_CANON="$(canonical_file "$STAGED")"
CAPTURE_DIR="$(mktemp -d /tmp/pebble-package-codesign.XXXXXX)"
chmod 700 "$CAPTURE_DIR"
REQUIREMENT_STDOUT="$CAPTURE_DIR/stdout.raw"
REQUIREMENT_STDERR="$CAPTURE_DIR/stderr.raw"
REQUIREMENT_FILE="$CAPTURE_DIR/requirement.normalized"
/usr/bin/perl -e "$CODESIGN_CHANNEL_PERL" -- capture "$OUTPUT_CANON" \
    "$REQUIREMENT_STDOUT" "$REQUIREMENT_STDERR" "$REQUIREMENT_FILE" || \
    die "invalid designated-requirement output"
[ -f "$REQUIREMENT_FILE" ] && [ ! -L "$REQUIREMENT_FILE" ] || \
    die "missing normalized designated requirement"
IFS= read -r REQUIREMENT < "$REQUIREMENT_FILE" || die "missing designated requirement"
[ -n "$REQUIREMENT" ] || die "missing designated requirement"
rm -rf -- "$CAPTURE_DIR"
CAPTURE_DIR=""

umask 077
TMP_MANIFEST="${MANIFEST}.tmp.$$"
{
    printf 'release_path=%s\n' "$EXECUTABLE"
    printf 'bundle_path=%s\n' "$OUTPUT_CANON"
    printf 'executable_path=%s\n' "$STAGED_CANON"
    printf 'pre_sign_input_sha256=%s\n' "$INPUT_HASH"
    printf 'pre_sign_staged_sha256=%s\n' "$STAGED_PRE_HASH"
    printf 'post_sign_executable_sha256=%s\n' "$POST_HASH"
    printf 'bundle_id=%s\n' "$BUNDLE_ID"
    printf 'cdhash=%s\n' "$CDHASH"
    printf 'designated_requirement=%s\n' "$REQUIREMENT"
    printf 'sealed_resources=true\n'
} > "$TMP_MANIFEST"
mv "$TMP_MANIFEST" "$MANIFEST"
chmod 600 "$MANIFEST"
printf 'packaged_sha256=%s cdhash=%s\n' "$POST_HASH" "$CDHASH"
