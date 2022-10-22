#
#  Copyright (c) 2011, Peter Haag
#  All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#	  this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright notice,
#	  this list of conditions and the following disclaimer in the documentation
#	  and/or other materials provided with the distribution.
#   * Neither the name of the author nor the names of its contributors may be
#	  used to endorse or promote products derived from this software without
#	  specific prior written permission.
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
#  $Id: Nfsync.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

package Nfsync;

use strict;
use warnings;

use IPC::SysV qw(IPC_CREAT);
use IPC::SysV qw(IPC_NOWAIT);
use IPC::SysV qw(IPC_PRIVATE);
use IPC::SysV qw(IPC_RMID);

my $semlock;

sub seminit {
	$semlock = semget(IPC_PRIVATE, 1, 0600 | IPC_CREAT ) || die "Can not get semaphore: $!";
	semsignal($semlock);
} # End of seminit

sub semclean {
	semctl($semlock, 0, &IPC_RMID, 0);
} # End of semclean

sub semwait {
    my $sem=$semlock;
    semop($sem, pack("s3", 0, -1, 0)) || warn "semopt(): $!\n";
} # End of semwait

sub semnowait {
    my $sem=$semlock;
    return semop($sem, pack("s3", 0, -1, IPC_NOWAIT));
} # End of semnowait

sub semsignal {
    my $sem=$semlock;
    semop($sem, pack("s3", 0, +1, 0)) || warn "semopt(): $!\n";
} # End of semsignal

1;
