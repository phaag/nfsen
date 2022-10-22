#!%%PERL%%
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	 this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	 this list of conditions and the following disclaimer in the documentation
#	 and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#	 used to endorse or promote products derived from this software without
#	 specific prior written permission.
#
#  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
#  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
#  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
#  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
#  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
#  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
#  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
#  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
#  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
#  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
#  POSSIBILITY OF SUCH DAMAGE.
#
#  $Author: peter $
#
#  $Id: Lookup.pm 61 2014-04-03 09:33:20Z peter $
#
#  $LastChangedRevision: 61 $

package Lookup;

use strict;
use warnings;
use Socket;
use IO::Socket::INET;
use Socket;
use AbuseWhois;
use Log;

sub Lookup {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'lookup'} ) {
		print $socket "<h3>Missing lookup parameter</h3>\n";
		return;
	}
	my $lookup = $$opts{'lookup'};

	my ($ip, $port);
	# IPv4/port
	if ( $lookup =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{1,5})$/ ) {
		$ip   = $1;
		$port = $2;
		# IPv4 ICMP
	} elsif ( $lookup =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d+\.\d+)$/ ) {
		$ip   = $1;
		$port = $2;
	# IPv4
	} elsif ( $lookup =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/ ) {
		$ip   = $1;
		$port = 0;
	# IPv6/port
	} elsif ( $lookup =~ /^([0-9a-f]+[0-9a-f:]+)\.(\d{1,5})$/ ) {
		$ip   = $1;
	# IPv6 ICMP
	} elsif ( $lookup =~ /^([0-9a-f]+[0-9a-f:]+)\.(\d+\.\d+)$/ ) {
		$ip   = $1;
	# IPv6
	} elsif ( $lookup =~ /^([0-9a-f]+[0-9a-f:]+)$/ ) {
		$ip   = $1;
		$port = 0;
	} elsif ( $lookup =~ /^([0-9a-f]+[0-9a-f:]+\.\.[0-9a-f:]+)/ ) {
		print $socket "Use IPv6 long format for IPv6lookup<br>";
		return;
	} else {
		print $socket "Can not decode IP address<br>";
		return;
	} 

#   print $socket "Port: $port<br>";

	AbuseWhois::Query($socket, $ip);

} # End of Lookup

1;
