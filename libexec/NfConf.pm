#!%%PERL%%
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
#  $Id: NfConf.pm 69 2014-06-23 19:27:50Z peter $
#
#  $LastChangedRevision: 69 $

package NfConf;

use strict;
use Log;

our $BASEDIR;
our $BINDIR;
our $LIBEXECDIR;
our $CONFDIR;
our $DOCDIR;
our $VARDIR;
our $PROFILEDATADIR;
our $PROFILESTATDIR;
our $PLUGINDIR;
our $PREFIX;
our $USER;
our $GROUP;
our $WWWUSER;
our $WWWGROUP;
our $BUFFLEN;
our $SUBDIRLAYOUT;
our $DISKLIMIT;
our $PROFILERS;
our $COMMSOCKET;
our %sources;
our %sim;
our %plugins;
our %PluginConf;
our $HTMLDIR;
our $low_water;
our $syslog_facility;
our $ZIPcollected;
our $ZIPprofiles;
our $InterruptExpire;
our $EXTENSIONS;
our $PIDDIR;
our $FILTERDIR;
our $FORMATDIR;
our $DEBUG;
our $AllowsSystemCMD;
our $SIMmode;
our $Refresh;
our $PERL_HAS_MEMLEAK;
our $BACKEND_PLUGINDIR;
our $PICDIR;
our $NFPROFILEOPTS;
our $NFEXPIREOPTS;

# Alerting email vars
our $MAIL_FROM;
our $MAIL_BODY;
our $SMTP_SERVER;

our $RRDoffset;
our $UID;
our $GID;
our $LogSocket;

our $CYCLETIME;

#
# Loads the config from nfsen.conf file
# returns 1 on success. 
# returns undef if failed. Set Log:ERROR
sub LoadConfig {
	my $InitConfigFile = shift;

	my $CONFFILE = defined $InitConfigFile ? $InitConfigFile : "%%CONFDIR%%/nfsen.conf";
	if ( !-f "$CONFFILE" ) {
		$Log::ERROR = "No NFSEN config file found.";
		return undef;
	}
	
	# preset default values:
	$CYCLETIME		 = 300;
	$DEBUG			 = 0;
	$BASEDIR		 = undef;
	$BINDIR			 = undef;
	$LIBEXECDIR		 = undef;
	$CONFDIR		 = undef;
	$DOCDIR			 = undef;
	$VARDIR			 = undef;
	$PROFILEDATADIR	 = undef;
	$PROFILESTATDIR	 = undef;
	$PLUGINDIR		 = undef;
	$PREFIX			 = '/usr/local/bin';
	$USER			 = 'nobody';
	$GROUP			 = undef;
	$WWWUSER		 = $USER;
	$WWWGROUP		 = 'www';
	$BUFFLEN		 = undef;
	$EXTENSIONS		 = undef;
	$SUBDIRLAYOUT	 = 0;
	$DISKLIMIT		 = 98;
	$PROFILERS		 = 1;
	$COMMSOCKET		 = undef;
	%sources		 = ();
	%sim		 	 = ();
	%PluginConf	 	 = ();
	$HTMLDIR		 = "/var/www/htdocs/nfsen";
	$low_water		 = 90;
	$syslog_facility = 'local3';
	$RRDoffset	 	 = 0;
	$SIMmode		 = 0;
	$Refresh		 = $CYCLETIME;
	$AllowsSystemCMD = 0;
	$PICDIR			 = undef;
	$FILTERDIR		 = undef;
	$FORMATDIR		 = undef;

	$MAIL_FROM		 = undef;
	$MAIL_BODY		 = q{Alert '@alert@' triggered at timeslot @timeslot@};
	$SMTP_SERVER	 = '';

	$ZIPcollected	 = 1;
	$ZIPprofiles	 = 1;
	$InterruptExpire = 0;

	$NFPROFILEOPTS	 = '';
	$NFEXPIREOPTS	 = '';

	$PERL_HAS_MEMLEAK = 0;

	my $log_type 	= $^V =~ /5.10/ ? 'native' : 'unix';

	$LogSocket	= $^O eq "solaris" ? 'stream' : $log_type;

	# Read Configuration
	if ( ! open( TMP, $CONFFILE) ) {
		die "Can't read config file '$CONFFILE': $!\n";
	}
	close TMP;

	if ( !do $CONFFILE ) {
		$Log::ERROR = "Errors in config file: $@";
		return undef;
	}

	if ( defined $BASEDIR && ! -d $BASEDIR && defined $InitConfigFile ) {
		mkdir $BASEDIR or
			$Log::ERROR = "Can not create BASEDIR '$BASEDIR': $!",
			return undef;
	}

	if ( defined $BASEDIR && ! -d $BASEDIR ) {
		$Log::ERROR = "Config seems to be buggy. BASEDIR '$BASEDIR' not found!";
		return undef;
	}

	if ( !defined $VARDIR ) {
		$VARDIR = "$BASEDIR/var";
	}

	if ( !defined $PIDDIR ) {
		$PIDDIR = "$VARDIR/run";
	}

	if ( !defined $FILTERDIR ) {
		$FILTERDIR = "$VARDIR/filters";
	}

	if ( !defined $FORMATDIR ) {
		$FORMATDIR = "$VARDIR/fmt";
	}

	if ( !defined $COMMSOCKET ) {
		$COMMSOCKET = "$PIDDIR/nfsen.comm";
	}

	if ( !defined $PICDIR ) {
		$PICDIR = $BACKEND_PLUGINDIR;
	}

	if ( !defined $EXTENSIONS ) {
		$EXTENSIONS = '';
	} else {
		$EXTENSIONS = "-T $EXTENSIONS";
	}

	my ($login,$pass,$uid,$gid) = getpwnam($USER);
	if ( !defined $login ) {
		$Log::ERROR =  "NFSEN user '$USER' not found on this system ";
		return undef;
	}

	$UID = $uid;
	if ( defined $WWWGROUP ) {
		$gid  = getgrnam($WWWGROUP);
		if ( !defined $gid ) {
			$Log::ERROR =  "NFSEN group '$WWWGROUP' not found on this system ";
			return undef;
		}
	}
	$GID = $gid;


	$Log::ERROR = undef ;
	return 1;

} # End of LoadConfig

1;
