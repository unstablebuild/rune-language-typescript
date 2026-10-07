#!/usr/bin/env perl
# Runs a stdio language server, completes the LSP initialize handshake and
# shuts the server down. Exits non-zero unless the server answers initialize
# with its capabilities and then exits cleanly, all within the timeout.
#
# The server exits as soon as its input closes, possibly before it answers,
# so the handshake has to wait for each response instead of piping a script.
#
# Usage: lsp-smoke.pl <command> [args...]
use strict;
use warnings;
use IO::Handle;
use IPC::Open2;

@ARGV or die "usage: $0 <command> [args...]\n";

my $timeout = 60;
my $pid = open2(my $out, my $in, @ARGV);
binmode $out;
binmode $in;

$SIG{ALRM} = sub {
	kill 'KILL', $pid;
	die "language server did not finish the handshake within ${timeout}s\n";
};
alarm $timeout;

sub send_msg {
	my ($body) = @_;
	print $in 'Content-Length: ' . length($body) . "\r\n\r\n" . $body;
	$in->flush;
}

sub read_msg {
	my $len;
	while (my $line = <$out>) {
		last if $line =~ /^\r?\n\z/;
		$len = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
	}
	defined $len or die "language server closed its output\n";
	my $body = '';
	while (length($body) < $len) {
		read($out, $body, $len - length($body), length($body))
			or die "language server closed its output\n";
	}
	return $body;
}

# await returns the response to request <id>. It skips notifications and
# answers the server's own requests, such as client/registerCapability, with
# a null result: the server waits for those before it handles anything else.
sub await {
	my ($id) = @_;
	while (1) {
		my $body = read_msg();
		my ($msg_id) = $body =~ /"id":\s*("[^"]*"|\d+)/;
		next unless defined $msg_id;
		if ($body =~ /"method":/) {
			send_msg('{"jsonrpc":"2.0","id":' . $msg_id . ',"result":null}');
			next;
		}
		return $body if $msg_id eq $id;
	}
}

send_msg('{"jsonrpc":"2.0","id":1,"method":"initialize",'
	. '"params":{"processId":null,"rootUri":null,"capabilities":{}}}');
my $init = await(1);
$init =~ /"result":\s*\{.*"capabilities":/s or die "initialize failed: $init\n";
send_msg('{"jsonrpc":"2.0","method":"initialized","params":{}}');
send_msg('{"jsonrpc":"2.0","id":2,"method":"shutdown"}');
await(2);
send_msg('{"jsonrpc":"2.0","method":"exit"}');
close $in;
waitpid $pid, 0;
alarm 0;
$? == 0 or die 'language server exited with status ' . ($? >> 8) . "\n";
print "initialize answered with capabilities\n";