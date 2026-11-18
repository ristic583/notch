#!/usr/bin/perl
# Loads MediaRemoteBridge.dylib into /usr/bin/perl (an Apple platform binary,
# which MediaRemote still serves on macOS 15.4+) and hands control to it.
use strict;
use warnings;
use DynaLoader;

my $path = shift @ARGV or die "usage: $0 /path/to/MediaRemoteBridge.dylib\n";
my $lib = DynaLoader::dl_load_file($path, 0)
    or die "notch-bridge: cannot load $path: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "NotchBridgeMain")
    or die "notch-bridge: NotchBridgeMain not found\n";
DynaLoader::dl_install_xsub("main::notch_bridge_main", $sym);
notch_bridge_main();
