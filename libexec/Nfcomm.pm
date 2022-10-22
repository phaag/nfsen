#!/usr/bin/perl
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
#  $Id: Nfcomm.pm 71 2017-01-19 16:16:21Z peter $
#
#  $LastChangedRevision: 71 $
package Nfcomm;

use strict;

# BEGIN { $ENV{PATH} = '/usr/ucb:/bin' }

use Socket;
use Carp;
use POSIX 'strftime';
use POSIX 'setsid';
use POSIX ":sys_wait_h";
use Sys::Syslog;
use Nfsync;
use UNIVERSAL;

use Log;
use NfProfile;
use NfAlert;
use Lookup;

my %CMD_lookup = ( 
	# get commands
	'get-du'				=> 	\&NfSen::DiskUsage,
	'get-globals'   		=>   \&GetGlobals,
	'get-profilelist'		=> 	\&NfProfile::GetAllProfiles,
	'get-profilegroups'		=> 	\&NfProfile::GetProfilegroups,
	'get-frontendplugins'	=> 	\&NfSen::GetFrontendPlugins,
	'get-profile'			=> 	\&NfProfile::GetProfile,
	'get-channelstat'		=>	\&NfProfile::GetChannelstat, 
	'get-channelfilter'		=>	\&NfProfile::GetChannelfilter, 
	'get-formatlist'		=> 	\&NfSen::GetOutputFormats,
	'get-filterlist'		=> 	\&NfSen::GetDefaultFilterList,
	'get-filter'			=> 	\&NfSen::GetDefaultFilter,
	'get-alertlist'			=> 	\&NfAlert::GetAllAlerts,
	'get-alert'				=> 	\&NfAlert::GetAlert,
	'get-alertfilter'		=> 	\&NfAlert::GetAlertFilter,
	'get-alertcondition'	=> 	\&GetAlertConditions,
	'get-alertgraph'		=>	\&NfAlert::GetAlertGraph,

	'get-statinfo'			=>	\&NfProfile::GetStatinfo, 
	'get-picture'			=>	\&NfProfile::SendPicture,
	'get-anypicture'		=>	\&NfSen::SendAnyPicture,
	'get-detailsgraph'		=>	\&NfProfile::GetDetailsGraph,

	'get-peek'				=>	\&NfProfile::SearchPeak,
	# add command
	'add-profile'			=> 	\&NfProfile::AddProfile,
	'add-channel'			=> 	\&NfProfile::AddProfileChannel,
	'add-format'			=> 	\&NfSen::AddOuputFormat,
	'add-filter'			=> 	\&NfSen::AddDefaultFilter,
	'add-alert'				=> 	\&NfAlert::AddAlert,

	'arm-alert'				=> 	\&NfAlert::ArmAlert,
	'run-alertaction'		=> 	\&RunPluginAction,

	# delete commands
	'delete-profile'		=> 	\&NfProfile::DeleteProfile,
	'delete-channel'		=> 	\&NfProfile::DeleteProfileChannel,
	'delete-format'			=> 	\&NfSen::DeleteOuputFormat,
	'delete-filter'			=> 	\&NfSen::DeleteDefaultFilter,
	'delete-alert'			=> 	\&NfAlert::DeleteAlert,

	'commit-profile'	=> 	\&NfProfile::CommitProfile,
	'cancel-profile'	=> 	\&NfProfile::CancelProfile,
	'modify-profile'	=> 	\&NfProfile::ModifyProfile,
	'modify-channel'	=> 	\&NfProfile::ModifyProfileChannel,
	'modify-alert'		=> 	\&NfAlert::ModifyAlert,
	'run-nfdump'		=> 	\&RunNfdump,
	'run-plugins'		=> 	\&RunPlugins,
	'rebuild-profile'	=> 	\&NfProfile::RebuildProfile,
	'expire-profile'	=> 	\&NfProfile::ExpireProfile,
	'reconfig'			=> 	\&Nfsources::Reconfig,

	'lookup'			=>	 \&Lookup::Lookup,
	'semcheck'   		=>   \&SemCheck,
	'signal'   			=>   \&OpSignal,
);


my $EOL 	= "\012";
my $EODATA 	= ".\n";
my $MAX_CHILDS = 20;

my $DEBUGENABLED = 1;
my $PRINT_DEBUG	= 0;

sub spawn;  # forward declaration

my $waitedpid = 0;
my $sigchld = 0;
my $done = 0;
my $child_exit;
my $num_childs = 0;
my $GMToffset = 0;
my $TZname = '';
my $nfsen_version = 'unknown';

my %ProfilePlugins;
my %modules_loaded;

our $in_periodic 	= 0;
my $cleanup_trigger = 0;

sub SIG_CHILD {
	my $child;
	$sigchld = 1;
	while (($waitedpid = waitpid(-1,WNOHANG)) > 0) {
		$child_exit = $?;
		my $exit_value  = $child_exit >> 8;
		my $signal_num  = $child_exit & 127;
		my $dumped_core = $child_exit & 128;
		$num_childs--;
		if ( $child_exit ) {
			syslog('debug', "comm child[$waitedpid] terminated Exit: $exit_value, Signal: $signal_num, Core: $dumped_core");
		} else {
			syslog('debug', "comm child[$waitedpid] terminated with no exit value");
		}
	}
	$SIG{CHLD} = \&SIG_CHILD;  # loathe sysV
} # End of SIG_CHILD

sub SIG_DIE {
	my $why = shift;
	syslog('err', "PANIC Comm Server dies: $why");
} # End of SIG_DIE

sub GetGlobals {
	my $socket  = shift;
	my $opts	= shift;

	# for the reason of daylight saving time, we need to check the UTC offset 
	my ($offhour, $offmin) = strftime('%z', localtime) =~ /^(.\d{2})(\d{2})/;
	$GMToffset 		= $offhour * 3600 + $offmin * 60;

	print $socket "_globals=\$SUBDIRLAYOUT = \"$NfConf::SUBDIRLAYOUT\";\n";
	print $socket "_globals=\$FRONTEND_PLUGINDIR = \"$NfConf::FRONTEND_PLUGINDIR\";\n";
	print $socket "_globals=\$RRDoffset = \"$NfConf::RRDoffset\";\n";

	print $socket "_globals=\$CYCLETIME = \"$NfConf::CYCLETIME\";\n";
	print $socket "_globals=\$Refresh = \"$NfConf::Refresh\";\n";
	print $socket "_globals=\$GMToffset = $GMToffset;\n";
	print $socket "_globals=\$TZname = \"$TZname\";\n";
	print $socket "_globals=\$AllowsSystemCMD = \"$NfConf::AllowsSystemCMD\";\n";
	print $socket "_globals=\$version = \"$nfsen_version\";\n";

	print $socket $EODATA;
	print $socket "OK command completed.\n";
} # End of GetGlobals


sub SemCheck {
	my $socket  = shift;
	my $opts	= shift;

	print $socket ". Semaphore Nfsync::semlock\n";
	print $socket $EODATA;
	if ( Nfsync::semnowait() ) {
		Nfsync::semsignal();
		print $socket "OK Semaphore available\n";
	} else {
		print $socket "ERR Semaphore not available\n";
	}
} 

sub OpSignal {
	my $socket  = shift;
	my $opts	= shift;

	if ( !exists $$opts{'flag'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing signal flag";
		return;
	} 

	my $flag = $$opts{'flag'};

	if ( $flag eq "start-periodic" ) {
		$in_periodic = 1;
	} elsif ( $flag eq "end-periodic" ) {
		$in_periodic = 0;
		$cleanup_trigger = 1;
	} else {
		print $socket $EODATA;
		print $socket "ERR Illegal flag '$flag'!\n";
		return;

	}

	print $socket $EODATA;
	print $socket "OK signal\n";

} # End of OpSignal

sub RunNfdump {
	my $socket 	= shift;
	my $opts 	= shift;

	my $args = exists $$opts{'args'} ? $$opts{'args'} : '';

	my @FilterChain = ();
	if ( exists $$opts{'srcselector'} ) {
		my $dirlist;
		my $ret = NfProfile::CompileFileArg($opts, \$dirlist, \@FilterChain);
		if ( $ret ne "ok" ) {
			print $socket $EODATA;
			print $socket "ERR $ret\n";
			return;
		}
		$args = "$dirlist $args";
	}

	my $filter = 'any';
	if ( exists $$opts{'filter'} ) {
    	my @_tmp;
    	foreach my $line ( @{$$opts{'filter'}} ) {
        	next if $line =~ /^\s*#/;
	
        	if ( $line =~ /(.+)#/ ) {
            	push @_tmp, $1;
        	} else {
            	push @_tmp, $line;
        	}
	
    	}
    	$filter = join "\n", @_tmp;
	}

	if ( $filter =~ /[^\s!-~\n]+/ || $filter =~ /['"`;\\]/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in filter\n";
		return;
	}

	if ( $args =~ /[^\s!-~\n]+/ || $args =~ /['"`;\\]/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in argument list\n";
		return;
	}

	print "DEBUG: Stripped filer: '$filter'\n" if $PRINT_DEBUG;

	if ( exists $$opts{'and_filter'} ) {
		my $name = $$opts{'and_filter'};
		if ( $name =~ /[^A-Za-z0-9\-+_]+/ ) {
			print $socket $EODATA;
			print $socket "ERR Illegal characters in filter name '$name': '$&'!\n";
			return;
		}

		if ( !-f "$NfConf::FILTERDIR/$name" ) {
			print $socket $EODATA;
			print $socket "ERR filter '$name' No such filter!\n";
			return;
		}

		my @_tmp;
		if ( open FILTER, "$NfConf::FILTERDIR/$name" ) {
			@_tmp = <FILTER>;
			close FILTER;
		} else {
			print $socket $EODATA;
			print $socket "ERR filter '$name': $!!\n";
			return;
		}
		if ( $filter eq 'any' ) {
			$filter = "(" . join("", @_tmp) . ")";
		} else {
			$filter = " ($filter) and (" . join("", @_tmp) . ")";
		}
	}

	if ( scalar @FilterChain > 0 ) {
		if ( $filter eq 'any' ) {
			$filter = "(" . join("\n", @FilterChain) . ")";
		} else {
			$filter = "(" . join("\n", @FilterChain) . ") and ( $filter )";
		}
	}
	my @lines;
	local $SIG{CHLD} = 'DEFAULT';
	print $socket ".run nfdump $args \n";
	foreach my $line ( split "\n", $filter ) {
		print $socket "_filter=$line\n";
	}
	print $socket "arg=$args\n";
	my $pid = open(NFDUMP, "$NfConf::PREFIX/nfdump $args '$filter' 2>&1|");
	if ( !$pid ) {
		my $err = "ERR nfdump run error: $!\n";
		print $socket $EODATA;
		print $socket $err;
		return;
	}
	print $socket ".pid: $pid\n";
	while ( <NFDUMP> ) {
		print $socket "_nfdump=$_";
	}
	my $nfdump_exit = 0;
	if ( !close NFDUMP ) {
		$nfdump_exit = $?;
		my $exit_value  = $nfdump_exit >> 8;
		my $signal_num  = $nfdump_exit & 127;
		my $dumped_core = $nfdump_exit & 128;
		syslog('err', "Run nfdump failed: Exit: $exit_value, Signal: $signal_num, Coredump: $dumped_core");
	};
	print  $socket "exit=$nfdump_exit\n";

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of RunNfdump

sub GetAlertConditions {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	}

	if ( !NfAlert::AlertExists($alert)) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	} 

	if ( !exists $$opts{'alertfile'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing alert flow file";
		return;
	} 
	my $alertfile = $$opts{'alertfile'};
	if ( ! -f $alertfile ) {
		print $socket $EODATA;
		print $socket "ERR alert flow file '$alertfile' does not exists!\n";
		return;
	}

	if ( !exists $$opts{'plugin'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing plugin name";
		return;
	} 
	my $plugin = $$opts{'plugin'};
	if ( $plugin =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in plugin name '$plugin'!\n";
		return;
	}

	if ( !exists $NfAlert::AlertPluginsCondition{$plugin} ) {
		print $socket $EODATA;
		print $socket "ERR Plugin '$plugin' does not exists or has no alert condition function\n";
		return;
	}

	if ( !exists $$opts{'timeslot'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing plugin name";
		return;
	} 
	my $timeslot = $$opts{'timeslot'};
	if ( !NfSen::ValidISO($timeslot) ) {
		print $socket $EODATA;
		print $socket "ERR Not a valid timeslot '$timeslot'!\n";
		return;
	}

	# now query the plugin

	my $ret;
	my $sub = "${plugin}::alert_condition";
	no strict 'refs';
	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		local $SIG{'CHLD'} 	  = 'DEFAULT';
		$ret = &$sub( 
			{ 'alert' 	  => $alert, 
			  'alertfile' => $alertfile, 
			  'timeslot'  => $timeslot }
		);
	};
	use strict 'refs';
	if ( $@ ) {
		print $socket $EODATA;
		print $socket "ERR Plugin: Error while running plugin '$plugin': $@ ";
		return;
	}
	
	print $socket "condition=$ret\n";
	print $socket $EODATA;
	print $socket "OK command completed\n";

} # End of GetAlertConditions

sub RunPluginAction {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'alert'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing alert name";
		return;
	} 
	my $alert = $$opts{'alert'};
	if ( $alert =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	}

	if ( !NfAlert::AlertExists($alert)) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in alert name '$alert'!\n";
		return;
	} 

	if ( !exists $$opts{'plugin'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing plugin name";
		return;
	} 
	my $plugin = $$opts{'plugin'};
	if ( $plugin =~ /[^A-Za-z0-9\-+_]+/ ) {
		print $socket $EODATA;
		print $socket "ERR Illegal characters in plugin name '$plugin'!\n";
		return;
	}

	if ( !exists $NfAlert::AlertPluginsAction{$plugin} ) {
		print $socket $EODATA;
		print $socket "ERR Plugin '$plugin' does not exists or has no alert action function\n";
		return;
	}

	if ( !exists $$opts{'timeslot'} ) {
		print $socket $EODATA;
		print $socket "ERR Missing plugin name";
		return;
	} 
	my $timeslot = $$opts{'timeslot'};
	if ( !NfSen::ValidISO($timeslot) ) {
		print $socket $EODATA;
		print $socket "ERR Not a valid timeslot '$timeslot'!\n";
		return;
	}

	# now run the plugin
	my $sub = "${plugin}::alert_action";
	no strict 'refs';
	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		local $SIG{'CHLD'} 	  = 'DEFAULT';
		my $ret = &$sub( 
			{ 'alert' 	  => $alert, 
			  'timeslot'  => $timeslot }
		);
	};
	use strict 'refs';
	if ( $@ ) {
		print $socket $EODATA;
		print $socket "ERR Plugin: Error while running plugin '$plugin': $@ ";
		return;
	}
	
	print $socket $EODATA;
	print $socket "OK command completed\n";

} # End of RunPluginAction


sub load_module {
	my $module = shift;

	my ($HasRun, $HasAlertCondition, $HasAlertAction) = (0, 0, 0);

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		require "$module.pm";
	};

	if ( my $err = $@ ) {
		syslog('err', "Loading plugin '$module': Failed.");
		syslog('err', "ERROR: $err");
		return ($HasRun, $HasAlertCondition, $HasAlertAction);
	}
	syslog('info', "Loading plugin '$module': Success");

	my $plugin_version = eval( "\$${module}::VERSION");
	if ( !defined $plugin_version ) {
		syslog('warning', "** Important **: Plugin '$module' is a legacy plugin.");
	}

	if ( !$module->can('Init') ) {
		syslog('err', "plugin '$module' has no Init() function. Skip plugin.");
		return ($HasRun, $HasAlertCondition, $HasAlertAction);
	}

	my $ret = eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		$module->Init();
	};
	if ( $@ ) {
		syslog('err', "Initializing plugin '$module': Module died: $@");
	} else {
		if ( $ret ) {
			$HasRun 			= $module->can('run') ? 1 : 0;
			$HasAlertCondition 	= $module->can('alert_condition') ? 1 : 0;
			$HasAlertAction 	= $module->can('alert_action') ? 1 : 0;
			syslog('info', "Initializing plugin '$module': Success");
			syslog('info', "plugin '$module': Profile plugin: $HasRun, Alert condition plugin: $HasAlertCondition, Alert action plugin: $HasAlertAction");
		} else {
			syslog('warning', "Initializing plugin '$module': Suspended");
		}
	}

	return ($HasRun, $HasAlertCondition, $HasAlertAction);

} # End of load_module

sub load_lookup {

	my $module = "Lookup_site";

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		require "$module.pm";
	};

	if ( my $err = $@ ) {
		syslog('info', "No site specific lookup module found");
		return \&Lookup::Lookup;
	}

	syslog('info', "Found site specific lookup module");

	if ( !$module->can('Lookup') ) {
		syslog('err', "site specific lookup module has no Lookup() function. Fallback to default.");
		return \&Lookup::Lookup;
	}

	if ( $module->can('Init') ) {
		syslog('info', "Run Init of site specific lookup module");
		my $ret = eval {
			local $SIG{'__DIE__'} = 'DEFAULT';
			$module->Init();
		};
		if ( $@ ) {
			syslog('err', "Initializing site specific lookup module failed: $@");
			return \&Lookup::Lookup;
		} 

		return \&Lookup_site::Lookup;
	}

	return \&Lookup_site::Lookup;

} # End of load_lookup


sub cleanup_module {
	my $module = shift;

	if ( !$module->can('Cleanup') ) {
		syslog('info', "plugin '$module' has no cleanup");
		return;
	}

	my $ret = eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		$module->Cleanup();
	};
	if ( $@ ) {
		syslog('err', "Cleanup plugin '$module': Module died: $@");
	} else {
		if ( $ret ) {
			syslog('info', "Cleanup plugin '$module' returned: $ret");
		} else {
			syslog('warning', "Cleanup plugin '$module': done.");
		}
	}
	return;

} # End of cleanup_module

sub CleanupPlugins {

	syslog('info', "Cleanup plugins");
	foreach my $module ( keys %modules_loaded ) {
		syslog('info', "Cleanup plugin: $module");
		cleanup_module($module);
	}

} # End of CleanupPlugins

sub LoadPlugins {

	if ( scalar @NfConf::plugins == 0 ) {
		return;
	}

	# That's were we find all the plugins
	# make warnings happy, as $NfConf::BACKEND_PLUGINDIR is used once only
	no warnings;
	unshift @INC, "$NfConf::BACKEND_PLUGINDIR";
	use warnings;

	# Load all plugins
	foreach my $plugin ( @NfConf::plugins ) {
		my $profilelist = $$plugin[0];
		my $module		= $$plugin[1];
		my @Profiles;

		# Check and report frontend plugin file
		if ( -f "$NfConf::FRONTEND_PLUGINDIR/${module}.php" ) {
			syslog('info', "Frontend module '${module}.php' found");
		}

		# Check and report backend plugin file
		if ( !-f "$NfConf::BACKEND_PLUGINDIR/${module}.pm" ) {
			syslog('info', "No backend module '${module}.pm' found");
			next;
		}

		# Try to load and initialize the module
		my ($HasRun, $HasAlertCondition, $HasAlertAction) = load_module($module);
		next if ( $HasRun == 0 && $HasAlertCondition == 0 && $HasAlertAction == 0 );

		$modules_loaded{$module} = 1;

		$NfAlert::AlertPluginsCondition{$module} = 1 if $HasAlertCondition;
		$NfAlert::AlertPluginsAction{$module} 	 = 1 if $HasAlertAction;

		if ( $profilelist ne '!' && $HasRun == 0 ) {
			syslog('err', "Plugin: '$module' has configured  profiles, but no 'run' function!");
			next;
		}
		next if ( $profilelist eq '!' || $HasRun == 0 );

		if ( $profilelist eq '*' ) {
			foreach my $profilegroup ( NfProfile::ProfileGroups() ) {
				push @Profiles, map( "$profilegroup/$_", NfProfile::ProfileList($profilegroup));
			}
			if ( scalar @Profiles == 0 ) {
				syslog('err', $Log::ERROR) if defined $Log::ERROR;
			}
		} else {
			@Profiles = split /\s*,\s*/, $profilelist;
		}

		foreach my $profileswitch ( @Profiles ) {
			my ($profilegroup, $profile);
			if ( $profileswitch =~ m#/# ) {
				($profilegroup, $profile) = split /\//, $profileswitch;
			} else {
				$profilegroup = '.';
				$profile = $profileswitch;
			}
			if ( ! NfProfile::ProfileExists($profile, $profilegroup)) {
				syslog('err', "Register plugin '$module' for profile '$profile' in profile group '$profilegroup' does not exists!");
				next;
			}
			if ( exists $ProfilePlugins{"$profilegroup/$profile"} ) {
				$ProfilePlugins{"$profilegroup/$profile"} .= ",$module";
			} else {
				$ProfilePlugins{"$profilegroup/$profile"}	= "$module";
			}
		}
	}
	foreach my $key ( keys %ProfilePlugins ) {
		syslog('info', "Plugins for profile         : $key - $ProfilePlugins{$key}");
	}
	foreach my $plugin ( keys %NfAlert::AlertPluginsCondition ) {
		syslog('info', "Plugins for Alert conditions: $plugin");
	}
	foreach my $plugin ( keys %NfAlert::AlertPluginsAction ) {
		syslog('info', "Plugins for Alert actions   : $plugin");
	}

	$CMD_lookup{'lookup'} = load_lookup();

} # End of LoadPlugins

sub RunPlugins {
	my $socket 	= shift;
	my $opts 	= shift;

	if ( !exists $$opts{'plugins'} ) {
		print $socket ".nothing to do\n";
		print $socket $EODATA;
		print $socket "OK command completed.\n";
		return;
	}

	if ( ref $$opts{'plugins'} ne "ARRAY" ) {
		print $socket $EODATA;
		syslog('err', "Plugins: argument vector array required, not a scalar.");
		print $socket "ERR argument vector array required, not a scalar.\n";
		return;
	}

	foreach my $opt ( @{$$opts{'plugins'}} ) {
		my ( $profilegroup, $profile, $timeslot ) = split ':', $opt;
		if ( !defined $profilegroup ) {
			syslog('warning', "Plugins: Can not decode '$opt'");
			next;
		}
		syslog('debug', "Plugin Cycle: $profilegroup, $profile, $timeslot");
		next unless exists $ProfilePlugins{"$profilegroup/$profile"};

		my $modules = $ProfilePlugins{"$profilegroup/$profile"};
		foreach my $module ( split ',', $modules ) {
			syslog("info", "Plugin Cycle: Time: $timeslot, Profile: $profile, Group: $profilegroup, Module: $module, ");
			my $sub = "${module}::run";
			my $plugin_version = eval( "\$${module}::VERSION");
			no strict 'refs';
			eval {
				local $SIG{'__DIE__'} = 'DEFAULT';
				local $SIG{'CHLD'} 	  = 'DEFAULT';
				if ( !defined $plugin_version ) {
					syslog("info", "Plugin $module: Run in compatibility mode.");
					&$sub($profile, $timeslot, $profilegroup);
				} else {
					&$sub( 
						{ 'profile' 	 => $profile, 
						  'profilegroup' => $profilegroup, 
						  'timeslot'	 => $timeslot }
					);
				}
			};
			use strict 'refs';
			if ( $@ ) {
				syslog("err", "Plugin: Error while running plugin '$module': $@ ");
			}
		}
	}

	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of RunPlugins

sub Setup_Server {
	my $version = shift;

	# in case we want INET sockets:
	my $port = shift;

	my $server;

	if ( 1 ) {
		# UNIX socket
		if ( !socket($server, PF_UNIX, SOCK_STREAM, 0) ) {
			$Log::ERROR = $!;
			return undef;
		}
		my $socket_path = $NfConf::COMMSOCKET;
		unlink $socket_path;
		my $uaddr = sockaddr_un($socket_path);
	
		my $ok = bind($server, $uaddr);
			if ( !$ok ) {
			$Log::ERROR = $!;
			close $server;
			return undef;
		}
		chown $NfConf::UID, $NfConf::GID, $socket_path; 
		chmod 0660, $socket_path;

	} else {
		# TCP Internet socket
		my $proto_tcp = getprotobyname('tcp');
		if ( !socket($server, PF_UNIX, SOCK_STREAM, $proto_tcp) ) {
			$Log::ERROR = $!;
			return undef;
		}
		my $ok = setsockopt($server, SOL_SOCKET, SO_REUSEADDR, pack("l", 1));
		if ( !$ok ) {
			$Log::ERROR = $!;
			close $server;
			return undef;
		}
	
		$ok = bind($server, sockaddr_in($port, INADDR_ANY));
		if ( !$ok ) {
			$Log::ERROR = $!;
			close $server;
			return undef;
		}
	}

	listen($server,SOMAXCONN);

	$Log::ERROR = undef;

	$SIG{INT} 		= sub { $done = 1; };
	$SIG{TERM} 		= sub { $done = 1; };
	$SIG{CHLD} 		= \&SIG_CHILD;
	$SIG{'__DIE__'} = \&SIG_DIE;

	$TZname 		= strftime('%Z', localtime);
	$nfsen_version 	= $version;

	return $server;

} # End of Setup_Server

sub spawn {
	my $coderef = shift;

	unless (@_ == 0 && $coderef && ref($coderef) eq 'CODE') {
		confess "usage: spawn CODEREF";
	}

	my $pid;
	if (!defined($pid = fork)) {
		print STDERR "comm server: cannot fork: $!";
		return;
	} elsif ($pid) {
		syslog('debug', "comm server started: $pid");
		return; # I'm the parent
	}
	# else I'm the child -- go spawn

	open(STDIN,  "<&Client")   || die "can't dup client to stdin";
	open(STDOUT, ">&Client")   || die "can't dup client to stdout";
	## open(STDERR, ">&STDOUT") || die "can't dup stdout to stderr";
	exit &$coderef();

} # End of spawn

sub CmdDecode {
	my $cmd_list = shift;
	my $silent	 = shift;

	my $cmd = shift @$cmd_list;
	return 0 if !defined $cmd;

	if ( $cmd eq '' ) {
		print $EODATA;
		print "OK I'm here", $EOL;
		return 0;
	}
	my ($command, $args) = $cmd =~ /^\s*([^\s]+)\s*(.*)/;
	if ( !defined $command ) {
		print $EODATA;
		print "ERR Failed to decode line '$cmd'", $EOL;
		syslog('err', "Failed to decode: $cmd");
		return 1;
	}

	my $is_binary = $command =~ s/^@// ? 1 : 0;
	syslog('debug', "Cmd Decode: $command");

	$silent = $silent || $is_binary;
	print ".Command is '$command' binary mode: $is_binary", $EOL unless $silent;

	if ( $cmd eq 'quit' ) {
		print $EODATA;
		print "OK Bye Bye", $EOL;
		return 1;
	}
	$cmd = $CMD_lookup{$command};
	if ( !defined $cmd ) {
		my ($plugin, $plugin_command ) = split /::/, $command;
		if ( !defined $plugin_command ) {
			print $EODATA;
			print "ERR Command unknown: '$command'", $EOL;
			return 0;
		}
		if ( !exists $modules_loaded{$plugin} ) {
			print $EODATA;
			print "ERR Plugin '$plugin' unknown", $EOL;
			return 0;
		}
		my $str = "\$${plugin}::cmd_lookup{'$plugin_command'}";
		$cmd = eval ( $str );
		if ( !defined $cmd ) {
			print $EODATA;
			print "ERR Plugin '$plugin' command unknown: '$plugin_command'", $EOL;
			return 0;
		}
	}
	my %opts;
	unshift @$cmd_list, $args if $args ne '';
	my $status = ArgDecode($cmd_list, \%opts);
	if ( $status ne "ok" ) {
		print $EODATA;
		print "ERR $status", $EOL;
		return 0;
	}
	foreach my $key ( keys %opts ) {
		my $value = $opts{$key};
		if ( ref $value eq "ARRAY" ) {
			foreach my $line ( @{$value} ) {
				print ".Key: '$key', value: '$line'", $EOL unless $silent;
			}
		} else {
			print ".Key: '$key', value: '$value'", $EOL unless $silent;
		}
	}
	my $socket = *STDOUT;
	&$cmd($socket, \%opts);

	return $is_binary;

} # End of CmdDecode

sub ArgDecode {
	my $arg_lines = shift;
	my $optref = shift;

	foreach my $arg ( @$arg_lines ) {
		my ($key, $value) = $arg =~ /\s*([^\s]+)\s*=\s*(.*)\s*/;
		if ( !defined $value || $key !~ /^[\._\w]\w[\w\-_]+/ ) {
			syslog('err', "Key format error for '$arg'");
			return "key format error";
		}
		if ( length($value) > 10240 ) {
			syslog('err', "Argument too long - length check failed.");
			return "value too long.";
		}
		if ( $key =~ /^_(.+)/ ) {
			$key = $1;
			if ( defined $$optref{$key} && ref $$optref{$key} ne 'ARRAY' ) {
				syslog('warning', "tried to assign an array entry to a scalar element for arg: '$arg'");
				return "tried to assign an array entry to a scalar element";
			}
			push @{$$optref{$key}}, $value;
		} else {
			if ( ref $$optref{$key} eq 'ARRAY' ) {
				syslog('warning', "tried to assign a scalar entry to an array entry for arg '$arg'");
				return "tried to assign a scalar entry to an array entry";
			}
			$$optref{$key} = $value;
		}
	}
	return "ok";

} # End of ArgDecode
# 	opts: 
# POST_varname => array( 
#	"required" 	=> 1, 						, 0 or 1 must exists in $opts, must not be undef
#	"allow_undef"=> 1, 						, 0 or 1 allow value to be undef
#	"default"  	=> undef, 					, if not exists or not defined use this default, maybe undef
#	"match" 	=> "/[^A-Za-z0-9\-+_]+/" 	, value must satify this reges, may be undef
#	"validate" 	=> undef),					, additional validate function to call for further processing, may be undef
#	"scrub"	-> 0							, 0 or 1 strip leading/trailing white spaces 
#
sub ParseOpts {
	my $opts 		= shift;
	my $parse_opts 	= shift;
	my $messages	= shift;

	my $form_data  = {};
	my $has_errors = 0;
	foreach my $varname ( keys %$parse_opts ) {
		# set the default
		my $value = $$parse_opts{$varname}{'default'};
		if ( !exists $$opts{"$varname"} ) {
			if ( $$parse_opts{$varname}{'required'} == 1 ) {
				$has_errors = 1;
				push @$messages, "Required key '$varname' not found";
				$$form_data{$varname} = $$parse_opts{$varname}{'default'};
				next;
			} elsif ( !defined $value ) {
				next;	# skip this value in list - not required, no default
			}

		} else {
			$value = $$opts{$varname};
		}
		if ( !defined $value ) {
			if ( $$parse_opts{$varname}{'allow_undef'} ) {
				$$form_data{$varname} = $value;
			} else {
				$$form_data{$varname} = $$parse_opts{$varname}{'default'};
				$has_errors = 1;
				push @$messages, "undef for key '$varname' not allowed";
				next;
			}
		} else {
			if ( $$parse_opts{$varname}{'scrub'} ) {
				$value =~ s/^\s+//;
				$value =~ s/\s+$//;
			}
		}
		if ( $$parse_opts{$varname}{'numeric'} ) {
			if ( $value =~ /^\D$/ ) {
				$has_errors = 1;
				$$form_data{$varname} = $$parse_opts{$varname}{'default'};
				push @$messages, "Value '$value' for key '$varname' not numeric";
				next;
			}
		}
		# the value is set here
		if ( defined $$parse_opts{$varname}{'match'} && defined $value && ref($value) ne 'ARRAY') {
			if ( ref($$parse_opts{$varname}{'match'}) eq 'ARRAY' ) {
				my $matched = 0;
				foreach my $item ( @{$$parse_opts{$varname}{'match'}} ) {
					print "'$item' ";
					if ( $$parse_opts{$varname}{'numeric'} ) {
						if ( $item == $value ) {
							$matched = 1;
						}
					} else {
						if ( $item eq $value ) {
							$matched = 1;
						}
					}
				}
				if ( $matched == 0 ) {
					$has_errors = 1;
					push @$messages, "Value '$value' not allowed for key '$varname'";
					$$form_data{$varname} = $$parse_opts{$varname}{'default'};
					next;
				}
			} else {
				if ( $value !~ m/$$parse_opts{$varname}{'match'}/ ) {
					$has_errors = 1;
					push @$messages, "Value '$value' not allowed for key '$varname'";
					$$form_data{$varname} = $$parse_opts{$varname}{'default'};
					next;
				}
			}
		} 

		# survived match - do we have a validate function?
		if ( defined $$parse_opts{$varname}{'validate'} ) {
			my $validatefunc = $$parse_opts{$varname}{'validate'};
			my $err = &$validatefunc( \$value, $parse_opts);
			if ($err == 0 ) {
				$has_errors = 0;
			} elsif ( $err == 1 ) {
				push @$messages, "Value '$value' not allowed for key '$varname'";
				$has_errors = 1;
				$value = $$parse_opts{$varname}{'default'};
			} elsif ( $err == 2 ) {
				push @$messages, "Value '$value' not allowed for key '$varname'";
				$has_errors = 1;
			}
		}
		# put it in array
		$$form_data{$varname} = $value;

	}

	return ( $form_data, $has_errors);

} # End of ParseOpts

sub RunServer {
	my $server = shift;

	my $paddr;
	my $timeout = 10;
	my $silent  = 0;
	my $alarm = 0;
	my $SIGpipe = 0;
	$SIG{ALRM} = sub { $alarm = 1; };
	$SIG{PIPE} = sub { $SIGpipe = 1 };
	while ( !$done ) {
		$paddr = accept(Client,$server);
		if ( !$paddr ) {
			if ( $sigchld == 0 ) {
				print "Unexpected return of accept()\n";
				sleep(1);
			} else {
				$sigchld = 0;
			}
			next;
		}
#		my($iport,$iaddr) = sockaddr_in($paddr);
#		my $name = gethostbyaddr($iaddr,AF_INET);

		$num_childs++;
		if ( $num_childs >= $MAX_CHILDS ) {
			syslog('warning', "Too many childs. Limit: $MAX_CHILDS");
			print Client "550 ERR too many open connections.", $EOL; 
			close Client;
			$num_childs--;
			next;
		}

		syslog('debug', "connection on UNIX socket ");

		spawn sub {
			$|=1;
			my $quit = 0;
	
			print "220 ", time(), " nfsend v0.1 ready ", $EOL;
			while ( !$quit && !$done ) {
				my @input;
				my $line;
				eval {
					local $SIG{'__DIE__'} = 'DEFAULT';
					local $SIG{ALRM} = sub { die "Timeout reading from socket!"; };
					local $SIG{PIPE} = sub { die "Broken PIPE while reading"; };
					my $done = 0;
				
					# read multi line command and args
					# command is terminated with a single '.' on a line
					while ( $done == 0 ) {
						alarm $timeout;
						$line = <STDIN>;
						alarm 0;
						die "Failed to read from socket: $!" unless defined $line;
						
						$line =~ s/$EOL$|\n$//;

						## the following block is for debugging purpose only
						if ( $line =~ /^\.(\w.+)$/ ) {
							my $internal = $1;
							if ( $internal =~/^timeout=(\d+)$/ ) {
								$timeout = $1;
								print "INFO Set timeout to $timeout", $EOL unless $silent;
							} elsif ( $DEBUGENABLED && $internal =~/^silent=(\d+)$/ ) {
								$silent = $1;
							} elsif ( $DEBUGENABLED && $internal =~/^debug=(\d+)$/ ) {
								$PRINT_DEBUG = $1 == 1 ? 1 : 0;
								print "INFO Set debug to $PRINT_DEBUG", $EOL unless $silent;
							} else {
								print "INFO Unknown internal: '$internal'", $EOL unless $silent;
							}
							next;
						}

						if ( $line eq '.' ) {
							$done = 1;
						} else {
							# a single '.' on a line is doubled
							# most likely not used, but for clean programming do it anyway
							if ( $line eq '..' ) {
								$line = '.';
							}
							push @input, $line;
						}
					}
				};
				if ($@) {
					print $EODATA;
					print "OK $@", $EOL;
					syslog('debug', "Failed: $@");
					$quit = 1;
				} else {
					if ( !defined $line ) {
						$quit = 1;
					} else {
						$quit = CmdDecode(\@input, $silent);
					}
				}
			}	
			if ( $cleanup_trigger ) {
				$cleanup_trigger = 0;
				syslog('debug', "Cleanup Routine");
				NfProfile::DeleteDelayed();
			}
			return 0;
		} # End of anonymous sub
		;
		close Client;
	}

	print "Quit Server: $waitedpid  !: $! \@: $@\n";
	syslog('info', "Quit comm server.");

} # end of RunServer

sub Close_server {
	my $server = shift;
	close $server;
	unlink $NfConf::COMMSOCKET;
} # End of Close_server

sub nfsend_connect {
	my $timeout = shift;

	my $socket_path = $NfConf::COMMSOCKET;
	my $nfsen_sock;

    if ( !socket($nfsen_sock, PF_UNIX, SOCK_STREAM, 0) ) {
		print "Can not create socket: $!\n";
		return undef;
	}
    if ( !connect($nfsen_sock, sockaddr_un($socket_path)) ) {
		print "Can not connect to nfsend: $!\n";
		return undef;
	} 

	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		local $SIG{ALRM} = sub { die "Timeout nfsend_connect"; };
		local $SIG{PIPE} = sub { die "Signal PIPE nfsend_connect"; };

		alarm 30;
		my $greeting = <$nfsen_sock>;
		alarm 0;
		if ( $greeting !~ /^220/ ) {
			print "Communication nfsend failed: $greeting\n";
			close($nfsen_sock);
			return undef;
		}
		if ( defined $timeout ) {
			send $nfsen_sock, ".timeout=$timeout\n", 0;
			my $ans = <$nfsen_sock>;
			if ( $ans !~ /INFO Set timeout/ ) {
				print "Failed to set timeout to $timeout: $ans\n";
				send $nfsen_sock, "quit\n.\n", 0;
				close($nfsen_sock);
				return undef;
			}
		}
	};
	if ($@) {
		print "Communication nfsend failed. $@\n";
		close($nfsen_sock);
		return undef;
	}

	return $nfsen_sock;

} # End of nfsend_connect

sub nfsend_disconnect {
	my $sock = shift;
	
	my $status;
	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		local $SIG{ALRM} = sub { die; };

		# send quit command
# print "Send: quit\n";
		send $sock, "quit\n", 0;
		send $sock, ".\n", 0;

		# read response
		alarm(30);
		my $line;
		while ( $line = <$sock> ) {

			# Debug output from nfsend
			if ( $line =~ /^\..+/ ) {
				print "DEBUG: $line" if $PRINT_DEBUG;
				next;
			}

			# End of Data
			if ( $line =~ /^\.$/ ) {
				$status = <$sock>;
				last;
			}
			last if $line =~ /^ERR|OK/;
		}
		alarm(0);
	};
	if ($@) {
		return  "ERR Communication nfsend failed. $@\n";
	}
	# we are done 
	close $sock;
	return $status;

} # End of nfsend_disconnect

sub nfsend_comm {
	my $sock	  = shift;
	my $command	  = shift;
	my $cmd_opts  = shift;
	my $out_list  = shift;
	my $comm_opts = shift;

	my $timeout = 30;
	if ( defined $comm_opts && defined $$comm_opts{'timeout'} ) {
		$timeout = $$comm_opts{'timeout'};
	}

	my $status = '';
	eval {
		local $SIG{'__DIE__'} = 'DEFAULT';
		local $SIG{ALRM} = sub { die "Timeout on socket"; };
		local $SIG{PIPE} = sub { die "Broken Pipe"; };

		# send command and options
# print "Send: $command\n";
		send $sock, "$command\n", 0;
		foreach my $key ( keys %$cmd_opts ) {
			if ( ref $$cmd_opts{$key} eq "ARRAY" ) {
				foreach my $line ( @{$$cmd_opts{$key}} ) {
					send $sock, "_$key=$line\n", 0;
				}
			} else {
# print "Send: $key=$$cmd_opts{$key}\n";
				send $sock, "$key=$$cmd_opts{$key}\n", 0;
			}
		}
# print "Send: EODATA\n";
		send $sock,".\n", 0;

		# read response
		alarm($timeout);
		while ( my $line = <$sock> ) {

			# Debug output from nfsend
			if ( $line =~ /^\..+/ ) {
				print "DEBUG: $line" if $PRINT_DEBUG;
				if ( defined $comm_opts && defined $$comm_opts{'info'} && $line =~ /^\.info /) {
					$line =~ s/\.info //;	# cut header
					$line =~ s/\n//;		# cut potential EOL
					print "Info: $line\n";
				}
				next;
			}

			# End of Data
			if ( $line =~ /^\.$/ ) {
# print "Received EODATA\n";
				$status = <$sock>;
				last;
			}

			my ($key, $value) = $line =~ /\s*([^=]+)=(.*)$/;

			if ( !defined $key ) {
# print "Could not decode: $line";
				next;
			}
			if ( $key =~ /^_(.*)$/ ) {
				$key = $1;
				if ( exists $$out_list{"$key"} ) {
					push @{$$out_list{"$key"}}, $value;
				} else {
					my $anon = [];
					push @{$anon}, $value;
					$$out_list{"$key"} = $anon;
				}
			} else {
				$$out_list{"$key"} = $value;
			}
			print "DEBUG: Key: $key, value: $value\n" if $PRINT_DEBUG;
		}
		alarm(0);
	};
	if ($@) {
		return  "ERR Communication nfsend failed. $@\n";
	}

	return $status;

} # End of nfsend_comm

sub socket_send_ok {
	my $socket = shift;
	my $args   = shift;

	foreach my $key ( keys %$args ) {
		if ( ref $$args{$key} eq 'ARRAY' ) {
			foreach my $elem ( @{$$args{$key}} ) {
				print $socket "_$key=$elem\n";
			}
		} else {
			print $socket "$key=$$args{$key}\n";
		}
	}
	print $socket $EODATA;
	print $socket "OK command completed.\n";

} # End of socket_send_ok

sub socket_send_error {
	my $socket = shift;
	my $error  = shift;

	print $socket $EODATA;
	print $socket "ERR $error\n";
	
} # End of socket_send_error

1;

