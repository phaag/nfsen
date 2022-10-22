#!/usr/bin/perl
#
#  Copyright (c) 2004, SWITCH - Teleinformatikdienste fuer Lehre und Forschung
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#     this list of conditions and the following disclaimer in the documentation
#     and/or other materials provided with the distribution.
#   * Neither the name of SWITCH nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
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
#  $Id: PluginTemplate.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

# Template for NfSen plugin
# See the demoplugin for an working example
package PluginTemplate;

use strict;
use NfSen;
use NfConf;

#
# The plugin may send any messages to syslog
# Do not initialize syslog, as this is done by 
# the main process nfsend
use Sys::Syslog;
  
sub run {
	my $profile  = shift;
	my $timeslot = shift;

	syslog('debug', "plugin run: Profile: $profile, Time: $timeslot");

	#
	# Do something and process the output and notify the duty team
	# ....

}

sub Init {
	syslog("info", "plugin: Init");

	# Init some vars
	return 1;
}

sub BEGIN {
	syslog("info", "plugin BEGIN");
	# Standard BEGIN Perl function - See Perl documentation
	# not used here
}

sub END {
	syslog("info", "plugin END");
	# Standard END Perl function - See Perl documentation
	# not used here
}

1;
