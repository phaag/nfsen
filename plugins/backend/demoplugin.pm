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
#  $Id: demoplugin.pm 41 2012-01-15 14:20:42Z peter $
#
#  $LastChangedRevision: 41 $

# Demo plugin for NfSen

# Name of the plugin
package demoplugin;

use strict;
use NfProfile;
use NfConf;

#
# The plugin may send any messages to syslog
# Do not initialize syslog, as this is done by 
# the main process nfsen-run
use Sys::Syslog;
  
our %cmd_lookup = (
	'try'	=> \&RunProc,
);

# This string identifies the plugin as a version 1.3.0 plugin. 
our $VERSION = 130;

my $EODATA 	= ".\n";

my ( $nfdump, $PROFILEDIR );

#
# Define a nice filter: 
# We like to see flows containing more than 500000 packets
my $nf_filter = 'packets > 500000';

sub RunProc {
	my $socket  = shift;	# scalar
	my $opts	= shift;	# reference to a hash

	# error checking example
	if ( !exists $$opts{'colours'} ) {
		Nfcomm::socket_send_error($socket, "Missing value");
		return;
	}

	# retrieve values passed by frontend
	# two scalars
	my $colour1 = $$opts{'colour1'};
	my $colour2 = $$opts{'colour2'};

	# one array as arrayref
	my $colours = $$opts{'colours'};

	my @othercolours = ( 'red', 'blue' );

	# Prepare answer
	my %args;
	$args{'string'} = "Greetings from backend plugin. Got colour values: '$colour1' and '$colour2'";
	$args{'othercolours'} = \@othercolours;

	Nfcomm::socket_send_ok($socket, \%args);

} # End of RunProc

#
# Periodic data processing function
#	input:	hash reference including the items:
#			'profile'		profile name
#			'profilegroup'	profile group
#			'timeslot' 		time of slot to process: Format yyyymmddHHMM e.g. 200503031200
sub run {
	my $argref 		 = shift;
	my $profile 	 = $$argref{'profile'};
	my $profilegroup = $$argref{'profilegroup'};
	my $timeslot 	 = $$argref{'timeslot'};

	syslog('debug', "demoplugin run: Profilegroup: $profilegroup, Profile: $profile, Time: $timeslot");

	my %profileinfo     = NfProfile::ReadProfile($profile, $profilegroup);
	my $profilepath 	= NfProfile::ProfilePath($profile, $profilegroup);
	my $all_sources		= join ':', keys %{$profileinfo{'channel'}};
	my $netflow_sources = "$PROFILEDIR/$profilepath/$all_sources";

	syslog('debug', "demoplugin args: '$netflow_sources'");

} # End of run

#
# Alert condition function.
# if defined it will be automatically listed as available plugin, when defining an alert.
# Called after flow filter is applied. Resulting flows stored in $alertflows file
# Should return 0 or 1 if condition is met or not
sub alert_condition {
	my $argref 		 = shift;

	my $alert 	   = $$argref{'alert'};
	my $alertflows = $$argref{'alertfile'};
	my $timeslot   = $$argref{'timeslot'};

	syslog('info', "Alert condition function called: alert: $alert, alertfile: $alertflows, timeslot: $timeslot");

	# add your code here

	return 1;
}

#
# Alert action function.
# if defined it will be automatically listed as available plugin, when defining an alert.
# Called when the trigger of an alert fires.
# Return value ignored
sub alert_action {
	my $argref 	 = shift;

	my $alert 	   = $$argref{'alert'};
	my $timeslot   = $$argref{'timeslot'};

	syslog('info', "Alert action function called: alert: $alert, timeslot: $timeslot");

	return 1;
}

#
# The Init function is called when the plugin is loaded. It's purpose is to give the plugin 
# the possibility to initialize itself. The plugin should return 1 for success or 0 for 
# failure. If the plugin fails to initialize, it's disabled and not used. Therefore, if
# you want to temporarily disable your plugin return 0 when Init is called.
#
sub Init {
	syslog("info", "demoplugin: Init");

	# Init some vars
	$nfdump  = "$NfConf::PREFIX/nfdump";
	$PROFILEDIR = "$NfConf::PROFILEDATADIR";

	return 1;
}

#
# The Cleanup function is called, when nfsend terminates. It's purpose is to give the
# plugin the possibility to cleanup itself. It's return value is discard.
sub Cleanup {
	syslog("info", "demoplugin Cleanup");
	# not used here
}

1;
