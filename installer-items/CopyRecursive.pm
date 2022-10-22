#!/usr/bin/perl
#
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
#  $Id: CopyRecursive.pm 27 2011-12-29 12:53:29Z peter $
#
#  $LastChangedRevision: 27 $

package CopyRecursive;

use strict;
use warnings;

use Carp;
use File::Copy; 
use File::Spec; #not really needed because File::Copy already gets it, but for good measure :)

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(fcopy rcopy dircopy);
our $VERSION = '0.06';
sub VERSION { $VERSION; }

our $MaxDepth = 0;
our $KeepMode = 1;
our $UID	  = undef;
our $GID	  = undef;
our $MODE	  = undef;
our $CopyLink = eval { symlink '',''; 1 } || 0;

sub fcopy { 
   if(-l $_[0] && $CopyLink) {
      symlink readlink(shift()), shift() or return;
   } else {  
      copy(@_) or return;
      chmod scalar((stat($_[0]))[2]), $_[1] if $KeepMode;
	  chown $UID, $GID, $_[1] if ( defined $UID and defined $GID );
	  chmod $MODE, $_[1] if defined $MODE;
   }
   return wantarray ? (1,0,0) : 1; # use 0's incase they do math on them and in case rcopy() is called in list context = no uninit val warnings 
}

sub rcopy { -d $_[0] ? dircopy(@_) : fcopy(@_) }

sub dircopy {
   croak "$_[0] and $_[1] are the same" if $_[0] eq $_[1];
   croak "$_[0] is not a directory" if !-d $_[0];
   croak "$_[1] is not a directory" if -e $_[1] && !-d $_[1];

	if ( ! -d $_[1] ) {
		mkdir $_[1];
		chown $UID, $GID, $_[1] if ( defined $UID and defined $GID );
	}
	if ( ! -d $_[1] ) {
		my @dirs = split '/', $_[1];
		my $mkpath = '';
		foreach my $dir ( @dirs ) {
			$mkpath = "$mkpath$dir/";
			if ( ! -d $mkpath ) {
				mkdir $mkpath unless -d $mkpath;
				chown $UID, $GID, $mkpath if ( defined $UID and defined $GID );
			}
		}
	}
	return if !-d $_[1];

   my $baseend = $_[1];
   my $level = 0;
   my $filen = 0;
   my $dirn = 0;

   my $recurs; #must be my()ed before sub {} since it calls itself
   $recurs =  sub {
      my ($str,$end,$buf) = @_;
      $filen++ if $end eq $baseend; 
      $dirn++ if $end eq $baseend;
	  if ( ! -d $end ) {
      	mkdir $end or return if !-d $end;
	  	chown $UID, $GID, $end if ( defined $UID and defined $GID );
      	chmod scalar((stat($str))[2]), $end if $KeepMode;
	  }
      if($MaxDepth && $MaxDepth =~ m/^\d+$/ && $level >= $MaxDepth) {
         return ($filen,$dirn,$level) if wantarray;
         return $filen;
      }
      $level++;

      opendir DIRH, $str or return;
      my @files = grep( $_ ne "." && $_ ne "..", readdir(DIRH));
      closedir DIRH;

      for(@files) {
         my $org = File::Spec->catfile($str,$_);
         my $new = File::Spec->catfile($end,$_);
		 unlink $new;
         if(-d $org) {
            $recurs->($org,$new,$buf) if defined $buf;
            $recurs->($org,$new) if !defined $buf;
            $filen++;
            $dirn++;
         } elsif(-l $org && $CopyLink) {
            if ( !symlink readlink($org), $new ) {
				warn "symlink failed for '$org': $!\n"; 
				return;
			}
         } else {
            copy($org,$new,$buf) or return if defined $buf;
            copy($org,$new) or return if !defined $buf;
            chmod scalar((stat($org))[2]), $new if $KeepMode;
	  		chown $UID, $GID, $new if ( defined $UID and defined $GID );
	  		chmod $MODE, $new if defined $MODE;
            $filen++;
         }
      }
   };

   $recurs->(@_);
   return ($filen,$dirn,$level) if wantarray;
   return $filen;
}
1;
__END__

=head1 NAME

File::Copy::Recursive - Perl extension for recursively copying files and directories

=head1 SYNOPSIS

  use File::Copy::Recursive qw(fcopy rcopy dircopy);

  fcopy($orig,$new[,$buf]) or die $!;
  rcopy($orig,$new[,$buf]) or die $!;
  dircopy($orig,$new[,$buf]) or die $!;

=head1 DESCRIPTION

This module copies directories recursively (or single files, well... singley) to an optional depth and attempts to preserve each file or directory's mode.

=head2 EXPORT

None by default. But you can export all the functions as in the example above.

=head2 fcopy()

This function uses File::Copy's copy() function to copy a file but not a directory.
One difference to File::Copy::copy() is that fcopy attempts to preserve the mode (see Preserving Mode below)
The optional $buf in the synopsis if the same as File::Copy::copy()'s 3rd argument
returns the same as File::Copy::copy() in scalar context and 1,0,0 in list context to accomidate rcopy()'s list context on regular files. (See below for more info)

=head2 dircopy()

This function recursively traverses the $orig directory's structure and recursively copies it to the $new directory.
$new is created if necessary.
It attempts to preserve the mode (see Preserving Mode below) and 
by default it copies all the way down into the directory, (see Managing Depth) below.
If a directory is not specified it croaks just like fcopy croaks if its not a file that is specified.

returns true or false, for true in scalar context it returns the number of files and directories copied,
In list context it returns the number of files and directories, number of directories only, depth level traversed.

  my $num_of_files_and_dirs = dircopy($orig,$new);
  my($num_of_files_and_dirs,$num_of_dirs,$depth_traversed) = dircopy($orig,$new);

=head2 rcopy()

This function will allow you to specify a file *or* directory. It calls fcopy() if its a file and dircopy() if its a directory.
If you call rcopy() (or fcopy() for that matter) on a file in list context, the values will be 1,0,0 since no directories and no depth are used. 
This is important becasue if its a directory in list context and there is only the initial directory the return value is 1,1,1.

=head2 Preserving Mode

By default a quiet attempt is made to change the new file or directory to the mode of the old one.
To turn this behavior off set 
  $File::Copy::Recursive::KeepMode
to false;

=head2 Managing Depth

You can set the maximum depth a directory structure is recursed by setting:
  $File::Copy::Recursive::MaxDepth 
to a whole number greater than 0.

=head2 SymLinks

If your system supports symlinks then symlinks will be copied as symlinks instead of as the target file.
Perl's symlink() is used instead of File::Copy's copy()
You can customize this behavior by setting $File::Copy::Recursive::CopyLink to a true or false value.
It is already set to true or false dending on your system's support of symlinks so you can check it with an if statement to see how it will behave:


    if($File::Copy::Recursive::CopyLink) {
        print "Symlinks will be preserved\n";
    } else {
        print "Symlinks will not be preserved because your system does not support it\n";
    }

=head1 SEE ALSO

 L<File::Copy> L<File::Spec>

=head1 AUTHOR

Daniel Muey, L<http://drmuey.com/cpan_contact.pl>

=head1 COPYRIGHT AND LICENSE

Copyright 2004 by Daniel Muey

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut

