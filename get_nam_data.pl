#!/usr/bin/env perl
#--------------------------------------------------------------
# get_nam_data.pl: downloads background meteorology data from NCEP
# for ASGS nowcasts and forecasts
#--------------------------------------------------------------
# Copyright(C) 2022 Jason Fleming
#
# This file is part of the ADCIRC Surge Guidance System (ASGS).
#
# The ASGS is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ASGS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with the ASGS.  If not, see <http://www.gnu.org/licenses/>.
#--------------------------------------------------------------
# ref: http://www.cpc.ncep.noaa.gov/products/wesley/fast_downloading_grib.html
#--------------------------------------------------------------
# sample line to test this script :
#
# perl get_nam_data.pl \
#                 --startcycle 2005082900
#                 --finishcycle 2005082906
#                 --stage nowcast
#                 --forecastcycle 00,06,12,18
#                 --backsite ftp.ncep.noaa.gov
#                 --backdir /pub/data/nccf/com/nam/prod
#--------------------------------------------------------------
$^W++;
use strict;
use Net::FTP;
use Getopt::Long;
use Cwd;
my $startcycle = "null";   # most recent cycle for which a nowcast was completed
my $finishcycle = "null";  # cycle to nowcast to (meaningless in the forecast stage)
my $stage = "null";      # nowcast | forecast
our $forecastcycle = "00,06,12,18";   # nam cycles to run a forecast
my $backsite = "ftp.ncep.noaa.gov";   # ncep ftp site for nam data
my $backdir = "/pub/data/nccf/com/nam/prod";    # dir on ncep ftp site
my @targetDirs; # directories to download NAM data from
our $max_retries = 20; # max number of times to attempt download of forecast file
our $num_retries = 0;
our $had_enough = 0;
my @nowcasts_downloaded;  # list of nowcast files that were successfully downloaded
#
our $this = "get_nam_data.pl";
#
our @grib_fields = ( "PRMSL","UGRD:10 m above ground","VGRD:10 m above ground" );
#
GetOptions(
           "startcycle=s" => \$startcycle,
           "finishcycle=s" => \$finishcycle,  
           "stage=s" => \$stage,
           "forecastcycle=s" => \$forecastcycle,
           "backsite=s" => \$backsite,
           "backdir=s" => \$backdir
);
&appMessage("DEBUG","Connecting to $backsite:$backdir");
our $dl = 0;   # true if we were able to download the file(s) successfully
# open ftp connection
our $ftp = Net::FTP->new($backsite, Debug => 0, Passive => 1);
unless ( defined $ftp ) {
   stderrMessage("ERROR","ftp: Cannot connect to $backsite: $@");
   printf STDOUT $dl;
   exit 1;
}
my $ftpLoginSuccess = $ftp->login("anonymous",'-anonymous@');
unless ( $ftpLoginSuccess ) {
   stderrMessage("ERROR","ftp: Cannot login: " . $ftp->message);
   printf STDOUT $dl;
   exit 1;
}
# switch to binary mode
$ftp->binary();
# cd to the directory containing the NAM files
my $hcDirSuccess = $ftp->cwd($backdir);
unless ( $hcDirSuccess ) {
   stderrMessage("ERROR",
       "ftp: Cannot change working directory to '$backdir': " . $ftp->message);
   printf STDOUT $dl;
   exit 1;
}
# if this is a forecast, jump to the sub to get the
# forecast data for this cycle
# J U M P   T O   F O R E C A S T
if ( $stage eq "forecast" ) {
   &getForecastData();
}
# N O W C A S T
# loop over target directories, grabbing all files relevant to a nowcast
foreach my $dir (@targetDirs) {
   stderrMessage("INFO","Downloading from directory '$dir'.");
   $hcDirSuccess = $ftp->cwd($dir);
   unless ( $hcDirSuccess ) {
      stderrMessage("ERROR",
         "ftp: Cannot change working directory to '$dir': " . $ftp->message);
      printf STDOUT $dl;
      exit;
   }
   # form list of the files we want
   # for the nowcast files, we need to create at least one deeper
   # directory to hold the data for the NAMtoOWI.pl -- the nowcast file
   # names do not indicate the date, and we may end up having to get
   # multiple nowcasts and stringing them together ... these nowcasts
   # may span more than one day -- the prefix "erl." is arbitrary I think
   # but NAMtoOWI.pl is hardcoded to look for it
   $dir =~ /nam.(\d+)/;
   my $dirDate = $1;
   my $localDir = $cycletime."/nowcast/erl.".substr($dirDate,2);
   unless ( -e $localDir ) {
      unless ( mkdir($localDir,0777) ) {
         stderrMessage("ERROR","Could not make the directory '$localDir': $!");
         die;
      }
   }
   #
   # get any nowcast files in this directory that are later than
   # the current adcirc time
   my @nowcastHours = qw/00 06 12 18/;
   # remove hours from the list if we are not interested in them
   foreach my $nchour (@nowcastHours) {
      if ( $dirDate == $date ) {
         if ( $nchour < $hour ) {
            next; # skip any that are before the current adcirc time
         }
      }
      if ( $dirDate == $cycledate ) {
         if ( $nchour > $cyclehour ) {
            next; # skip any that are after the most recent file we know of
         }
      }
      my $hourString = sprintf("%02d",$nchour);
      my $fbase = "nam.t".$hourString."z.awip1200.tm00";
      my $f = $fbase . ".grib2";
      my $idxfile = $f . ".idx";

      #my $success = $ftp->get($f,$localDir."/".$f);
      my $err = &partialGribDownload($dirDate, $f, $idxfile, $localDir);
      unless ( $err == 0 ) {
         stderrMessage("INFO","Get '$f' failed.");
         next;
      } else {
         stderrMessage("INFO","Download complete.");
         push(@nowcasts_downloaded,$dirDate.$hourString);
         #stderrMessage("DEBUG","Now have data for $dirDate$hourString.");
         $dl++;
      }
   }
   $hcDirSuccess = $ftp->cdup();
   unless ( $hcDirSuccess ) {
      stderrMessage("ERROR",
         "ftp: Cannot change working directory to parent of '$dir': " . $ftp->message);
      printf STDOUT $dl;
      exit;
   }
}
# check to see if we got all the nowcast files that are needed to span the
# time from the current hot start file to the latest files from
# the NCEP site. If not, and the NCEP site no longer has files that are
# needed, then check the alternate directories.
my $date_needed = $date;
my $hour_needed = $hour;
my $datetime_needed = $date_needed.$hour_needed; # start with the hotstart date
while ($datetime_needed <= $cycletime) {
   my $already_haveit = 0;
   # look through the list of downloaded files to see if we already have it
   foreach my $downloaded (@nowcasts_downloaded) {
      if ( $downloaded == $datetime_needed ) {
         #stderrMessage("DEBUG","Already downloaded nowcast data for '$datetime_needed'.");
         $already_haveit = 1;
      }
   }
   unless ( $already_haveit == 1 ) {
      # don't have it, look in alternate directories for it
      stderrMessage("DEBUG","Don't have nowcast data for '$datetime_needed', searching alternate directories.");
      if (@altnamdirs) {
         # loop through all the alternative directories
         foreach my $andir (@altnamdirs) {
            #stderrMessage("DEBUG","Checking '$andir'.");
            my @subdirs = glob("$andir/??????????");
            foreach my $subdir (@subdirs) {
               my $alt_location = $subdir."/nowcast/erl.".substr($date_needed,2)."/nam.t".$hour_needed."z.awip1200.tm00.grib2";
               #stderrMessage("DEBUG","Looking for '$alt_location'.");
               # does the file exist in this alternate directory?
               if ( -e $alt_location ) {
                  $localDir = $cycletime."/nowcast/erl.".substr($date_needed,2);
                  # perform a smoke test on the file we found to check that it is
                  # not corrupted (not a definitive test but better than nothing)
                  unless ( `$scriptdir/wgrib2 $alt_location -match PRMSL -inv - -text /dev/null` =~ /PRMSL/ ) {
                     stderrMessage("INFO","The file '$alt_location' appears to be corrupted and will not be used.");
                     next;
                  }
                  stderrMessage("DEBUG","Nowcast file '$alt_location' found. Copying to cycle directory '$localDir'.");
                  unless ( -e $localDir ) {
                     unless ( mkdir($localDir,0777) ) {
                        stderrMessage("ERROR","Could not make the directory '$localDir': $!");
                        die;
                     }
                  }
                  symlink($alt_location,$localDir."/nam.t".$hour_needed."z.awip1200.tm00.grib2");
                  $dl++;
                  $already_haveit = 1;
                  last;
               } else {
                  # file does not exist in this alternate directory
                  #stderrMessage("DEBUG","The file '$alt_location' was not found.");
               }
            }
            if ( $already_haveit == 1 ) {
               last;
            }
         }
      }
      if ( $already_haveit == 0 ) {
         stderrMessage("WARNING","Still missing the nowcast data for '$datetime_needed'.");
      }
   }
   # now add six hours to determine the next datetime for which we need nowcast
   # data
   $datetime_needed =~ /(\d\d\d\d)(\d\d)(\d\d)(\d\d)/;
   my $yn = $1;
   my $mn = $2;
   my $dn = $3;
   my $hn = $4;
   my ($ty, $tm, $td, $th, $tmin, $ts); # targeted nowcast time
   # now add 6 hours
   ($ty,$tm,$td,$th,$tmin,$ts) =
      Date::Calc::Add_Delta_DHMS($yn,$mn,$dn,$hn,0,0,0,6,0,0);
   # form the date and hour of the next nowcast data needed
   $date_needed = sprintf("%4d%02d%02d",$ty ,$tm, $td);
   $hour_needed = sprintf("%02d",$th);
   $datetime_needed = $date_needed.$hour_needed;
}
# if we found at least two files, we assume have enough for the next advisory
if ( $dl >= 2 ) {
   printf STDOUT $cycletime;
} else {
   printf STDOUT "0";
}
1;


#-----------------------------------------------------------
# FORECAST
#-----------------------------------------------------------
# now download all the files that are relevant to a forecast
sub getForecastData() {
   my @targetFiles="";
   # write a properties file to document when the forecast starts and ends
   unless ( open(FP,">$rundir/forecast.properties") ) {
      stderrMessage("ERROR","Could not open '$rundir/forecast.properties' for writing: $!.");
      exit 1;
   }
   # read the special purpose file that describes the latest cycle that we
   # have nowcasted to
   # FIXME : there has to be a better way
   unless ( open(CYCLENUM,"<$rundir/currentCycle") ) {
      stderrMessage("ERROR","Could not open '$rundir/currentCycle' for reading: $!.");
      exit 1;
   }
   <CYCLENUM> =~ /(\d+)/;
   my $cycletime = $1;
   stderrMessage("DEBUG","The cycle time for the forecast is '$cycletime'.");
   close(CYCLENUM);
   printf FP "forecastValidStart : $cycletime" . "0000\n";
   my $localDir = $cycletime."/$enstorm";
   my $cycledate = substr($cycletime,0,8);
   my $cyclehour = substr($cycletime,-2,2);
   $cycledate =~ /(\d\d\d\d)(\d\d)(\d\d)/;
   my $cdy = $1;
   my $cdm = $2;
   my $cdd = $3;
   #
   # Check to see if the cycle hour matches one that we are supposed to
   # run a forecast for. If so, write a file called "runme" in the
   # forecast directory.
   #
   # If not, check to see if an earlier cycle should have run, but
   # failed, and the failure was not made up in a later run. If so,
   # write the file called "runme" in the forecast directory.
   #
   # This will require us to calculate the cycle date and hour of the
   # cycle 6 hours prior to this one, and then to look in the rundir
   # for that directory.
   my $runme = 0;
   my $noforecast = 0;
   my $rationale = "scheduled";
   #stderrMessage("DEBUG","The cyclehour is '$cyclehour'.");
   foreach my $cycle (@forecastcycle) {
      if ( $cycle eq $cyclehour ) {
         $runme = 1;  # operator wants to forecast this cycle
         last;
      }
      # allow for the possibility that we aren't supposed to run any forecasts
      if ( $cycle eq "none" ) {
         $noforecast = 1; # operator doesn't want any forecasts
         last;
      }
   }
   # if the Operator strictly wants to only forecast certain cycles,
   # and this is not one of them, then do not run this forecast,
   # and prevent this forecast from running as an unscheduled
   # "make up" forecast for a previous forecast that was supposed
   # to run and did not
   if ( $runme == 0 && $forecastselection eq "strict" ) {
      $noforecast = 1;   # operator doesn't want a forecast to run for this cycle
   }
   # we may still want to run the forecast to make up for an earlier
   # forecast that failed or was otherwise missed (24 hour lookback)
   if ( $runme == 0 && $noforecast == 0 ) {
      my $earlier_success = 0; # 1 if an earlier run succeeded
      for ( my $i=-6; $i>=-24; $i-=6 ) {
         # determine date/time of previous cycle

         my ($pcy, $pcm, $pcd, $pch, $pcmin, $pcs); # previous cycle time
         # now subtract the right number of hours
        ($pcy,$pcm,$pcd,$pch,$pcmin,$pcs) =
          Date::Calc::Add_Delta_DHMS($cdy,$cdm,$cdd,$cyclehour,0,0,0,$i,0,0);
         # form the date and hour of the previous cycle time
         my $previous_date = sprintf("%4d%02d%02d",$pcy ,$pcm, $pcd);
         my $previous_hour = sprintf("%02d",$pch);
         my $previous_cycle = $previous_date.$previous_hour;
         stderrMessage("DEBUG","The previous cycle was '$previous_cycle'.");
         # check to see if the previous cycle forecast was scheduled to run
         my $was_scheduled = 0;
         foreach my $cycle (@forecastcycle) {
            if ( $cycle eq $previous_hour ) {
               stderrMessage("DEBUG","The previous cycle was scheduled to run a forecast.");
               $was_scheduled = 1;
               last;
            }
         }
         # since the ASGS will move failed ensemble directories out of
         # their parent cycle directory, the presence of the
         # padcswan.namforecast.run.finish or padcirc.namforecast.run.finish
         # files indicates that it was successful
         #
         # If the prior one is present, and was not scheduled, then
         # we'll assume it was a make-up run; in this case no need to
         # force this one. If it is present, and was scheduled, then no need
         # for any make up run.
         #
         # When looking for the previous runs, check the current run directory
         # as well as the local archive of previous successful runs
         my @prev_dirs;
         push(@prev_dirs,$rundir);
         push(@prev_dirs,$archivedruns);
         foreach my $dir (@prev_dirs) {
            if ( -e "$dir/$previous_cycle/$enstorm/padcswan.$enstorm.run.finish" || -e "$dir/$previous_cycle/$enstorm/padcirc.$enstorm.run.finish" ) {
               $earlier_success = 1;
               stderrMessage("DEBUG","The previous cycle completed successfully and was found at '$dir/$previous_cycle'.");
               last;
            }
         }
         if ( $earlier_success == 1 ) {
            stderrMessage("DEBUG","The previous cycle ran. No need for a make-up run.");
            last;
         } else {
            # ok the prior cycle did not run ... if it was supposed to
            # then force the current forecast to run
            if ( $was_scheduled == 1 ) {
               $rationale = "The previous cycle '$previous_cycle' did not successfully run a forecast, although it was scheduled. Forcing the current forecast '$cycletime' to run as a make-up run.";
               stderrMessage("DEBUG",$rationale);
               last;
            }
         }
      }
      if ( $earlier_success == 0 ) {
         $runme = 1;
      }
   }
   if ( $runme == 1 ) {
      unless (open(RUNME,">$localDir/runme") ) {
         stderrMessage("ERROR","Could not open '$localDir/runme' for writing: $!.");
         exit 1;
      }
      printf RUNME $rationale;
      close(RUNME);
   } else {
      # don't download forecast files that are not needed unless
      # specifically requested
      if ( $forecastdownload eq "only-to-run" ) {
         stderrMessage("INFO","This forecast is not scheduled to run so the files will not be downloaded.");
         printf STDOUT "forecast-not-needed";
         exit 0;
      }
   }
   #
   # download the forecast files
   stderrMessage("INFO","Downloading from directory 'nam.$cycledate'.");
   $hcDirSuccess = $ftp->cwd("nam.".$cycledate);
   unless ( $hcDirSuccess ) {
      stderrMessage("ERROR",
         "ftp: Cannot change working directory to 'nam.$cycledate': " . $ftp->message);
      printf STDOUT $dl;
      exit;
   }
   # forecast files are the list of files to retrieve
   for (my $i=0; $i<=$forecastlength; $i+=3 ) {
      my $hourString = sprintf("%02d",$cyclehour);
      my $f = "nam.t".$hourString."z.awip12".sprintf("%02d",$i).".tm00.grib2";
      # sometimes an error occurs in Net::FTP causing this script to bomb out;
      # the asgs will retry, but we don't want it to re-download stuff that it
      # already has
      if ( -e $localDir."/".$f ) {
         # perform a smoke test on the file we found to check that it is
         # not corrupted (not a definitive test but better than nothing)
         unless ( `$scriptdir/wgrib2 $localDir/$f -match PRMSL -inv - -text /dev/null` =~ /PRMSL/ ) {
            stderrMessage("INFO","The file '$localDir/$f' appears to be corrupted and will not be used.");
         } else {
            stderrMessage("INFO","'$f' has already been downloaded to '$localDir'.");
            $dl++;
            next;
         }
      }
      stderrMessage("INFO","Downloading '$f' to '$localDir'.");
      my $success = 0;
      $num_retries = 1;
      my $idxfile = $f . ".idx";
      while ( $success == 0 && $num_retries < $max_retries ) {
         my $stat = &partialGribDownload($cycledate, $f, $idxfile, $localDir);
         # my $stat = $ftp->get($f,$localDir."/".$f);
         unless ( $stat == 0 ) {
            stderrMessage("INFO","ftp: Get '$f' failed: " . $ftp->message);
            $num_retries++;
            #stderrMessage("DEBUG","num_retries is $num_retries");
            sleep 60;
         } else {
            $dl++;
            $success = 1;
            stderrMessage("INFO","Downloaded in $num_retries attempt(s).");
         }
      }
      if ( $num_retries >= $max_retries ) {
         $had_enough = 1;
         stderrMessage("INFO","Retried download more than $max_retries times. Giving up on downloading $f.");
         last;  # if we tried 10 times and couldn't get it, the files are
                # probably not there at all, so don't spend time trying to
                # get the rest of them
      }
   }
   if ( ($dl >= $forecastlength/3 ) || ($had_enough == 1) ) {
      printf STDOUT $cycletime;
   } else {
      printf STDOUT "0";
   }
   # determine the end date of the forecast for the forecast.properties file
   my $cyclehour = substr($cycletime,-2,2);
   $cycledate =~ /(\d\d\d\d)(\d\d)(\d\d)/;
   my $cdy = $1;
   my $cdm = $2;
   my $cdd = $3;
   my $cmin = 0;
   my $cs = 0;
   my ($ey,$em,$ed,$eh,$emin,$es) =
         Date::Calc::Add_Delta_DHMS($cdy,$cdm,$cdd,$cyclehour,$cmin,$cs,0,$dl*3,0,0);
                        #  yyyy mm  dd  hh
   my $end_date = sprintf("%04d%02d%02d%02d",$ey,$em,$ed,$eh);
   printf FP "forecastValidEnd : $end_date" . "0000\n";
   close(FP);
}
#
# perform partial grib download using curl
# only gets the U, V, P at mean sea level
sub partialGribDownload () {
   my $dirDate = shift;
   my $f = shift;
   my $idxfile = shift;
   my $localDir = shift;
   #--------------------------------------------------------
   #    G R I B   I N V E N T O R Y  A N D   R A N G E S
   #--------------------------------------------------------
   # FIXME: undo this hardcode for downloading files with curl using
   # https://nomads rather than $backsite
   my $idx = "https://nomads.ncep.noaa.gov$backdir/nam.$dirDate/$idxfile";
   # jgfdebug: save a local copy of the inventory file
   stderrMessage("DEBUG","Downloading '$idx' with the command 'curl -f -s $idx -o $localDir/$idxfile'.");
   my $err=system("curl -f -s $idx -o $localDir/$idxfile");
   if ( $err != 0 ) {
      stderrMessage("INFO","curl: Get '$idx' failed.");
      unlink("$localDir/$idxfile");
      return $err;
   }
   # download directly into list
   #stderrMessage("INFO","Downloading '$idx' with the command 'curl -f -s $idx'.");
   #my @gribInventoryLines = `curl -f -s $idx`; # the grib inventory file from the ftp site
   my @rangeLines;    # inventory with computed ranges
   my $last = 0;      # number of immediately preceding lines with same starting byte index
   my $lastnum = -1;  # starting byte range of previous line (or lines if there are repeats)
   my @old_lines;     # contiguous lines in inventory with same starting byte
   my $has_range = 0; # set to 1 if the inventory already has a range field
   #
   # open index file for this time period
   stderrMessage("INFO","Parsing '$idx' to determine byte ranges of U, V, and P.");
   unless ( open(GRIBINVENTORY,"<$localDir/$idxfile") ) {
      stderrMessage("ERROR","Could not open '$localDir/$idxfile' for appending: $!.");
      return 1;
   }
   while(<GRIBINVENTORY>) {
      chomp($_);
      #stderrMessage("INFO","$li");
      # check to see if this is grib2 inventory that already has a range field
      # if so, don't need to calculate the range
      if ($_ =~ /:range=/) {
         $has_range = 1;
         push(@rangeLines,"$_\n");
      } else {
         # grib1/2 inventory,
         #    c o m p u t e   r a n g e   f i e l d
         # inventory line format without range field e.g.:
         # 1:0:d=2021030106:PRMSL:mean sea level:anl:
         # 2:233889:d=2021030106:PRES:1 hybrid level:anl:
         # 3:476054:d=2021030106:RWMR:1 hybrid level:anl:
         my ($f1,$startingByteIndex,$rest) = split(/:/,$_,3);
         # see if the starting byte index is different on this line
         # compared to the previous one (and this is not the first line)
         if ($lastnum != $startingByteIndex && $last != 0) {
            # compute the end of the byte range for the previous line
            my $previousEndingByteIndex = $startingByteIndex - 1;
            # add this byte range to all the old_lines we've stored due to their
            # repeated starting byte index
            foreach my $ol (@old_lines) {
               $ol = "$ol:range=$lastnum-$previousEndingByteIndex\n";
            }
            # now add these old lines to the list of lines with our newly computed ranges
            @rangeLines = (@rangeLines,@old_lines);
            @old_lines = ();
            $last = 1;
         }  else {
            $last++;
         }
         push(@old_lines,$_);
         $lastnum = $startingByteIndex;
      }
   }
   close(GRIBINVENTORY);
   if ( $has_range == 0 ) {
      foreach my $ol (@old_lines) {
         $ol = "$ol:range=$lastnum\n";
      }
      @rangeLines = (@rangeLines,@old_lines);
   }
   #   r a n g e   f i e l d s   h a v e   n o w   b e e n   c o m p u t e d   o r   p r o v i d e d
   #
   # download and concatenate grib2 byte ranges
   # jgfdebug
   #foreach my $li (@rangeLines) {
   #   print $li;
   #}
   # now iterate through them and collect the relevant byte ranges
   my @ranges;      # byte ranges to download
   foreach my $li (@rangeLines) {
      my $match = 0;
      # check to see if the line matches one of the fields of interest
      foreach my $gf (@grib_fields) {
         if ( $li =~ /$gf/ ) {
            #print "$li matches $gf\n";
            # want to download this field
            chomp($li);
            $li =~ /:range=([0-9]*)-([0-9]*)/;
            my $newrange = $1 . "-" . $2;
            # don't request the same range twice in a row (e.g., U and V will have the same range)
            unless ( @ranges > 0 && $newrange eq $ranges[-1] ) {
               push(@ranges,$newrange);
            }
         }
      }
   }
   # now join selected ranges and actually download the specified data
   my $range=join(",",@ranges);
   stderrMessage("INFO","Downloading '$f' to '$localDir' with curl -f -s -r \"$range\" https://nomads.ncep.noaa.gov$backdir/nam.$dirDate/$f -o $localDir/$f.");
   my $err=system("curl -f -s -r \"$range\" https://nomads.ncep.noaa.gov$backdir/nam.$dirDate/$f -o $localDir/$f");
   if ( $err == 0 ) {
      stderrMessage("INFO","Download complete.");
      return 0;
      #stderrMessage("DEBUG","Now have data for $dirDate$hourString.");
   } else {
      stderrMessage("INFO","curl: Get '$f' failed.");
      unlink("$localDir/$f");
      return 1;
   }
}
#
# write a log message to stderr
sub stderrMessage () {
   my $level = shift;
   my $message = shift;
   my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
   (my $second, my $minute, my $hour, my $dayOfMonth, my $month, my $yearOffset, my $dayOfWeek, my $dayOfYear, my $daylightSavings) = localtime();
   my $year = 1900 + $yearOffset;
   my $hms = sprintf("%02d:%02d:%02d",$hour, $minute, $second);
   my $theTime = "[$year-$months[$month]-$dayOfMonth-T$hms]";
   printf STDERR "$theTime $level: $enstorm: get_nam.pl: $message\n";
}
#
# write a log message to a log file dedicated to this script (typically debug messages)
sub appMessage () {
   my $level = shift;
   my $message = shift;
   my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
   (my $second, my $minute, my $hour, my $dayOfMonth, my $month, my $yearOffset, my $dayOfWeek, my $dayOfYear, my $daylightSavings) = localtime();
   my $year = 1900 + $yearOffset;
   my $hms = sprintf("%02d:%02d:%02d",$hour, $minute, $second);
   my $theTime = "[$year-$months[$month]-$dayOfMonth-T$hms]";
   #
   # open an application log file for get_nam.pl
   unless ( open(APPLOGFILE,">>$rundir/get_nam.pl.log") ) {
      &stderrMessage("ERROR","Could not open $rundir/get_nam.pl.log for appending: $!.");
   }
   printf APPLOGFILE "$theTime $level: $enstorm: get_nam.pl: $message\n";
   close(APPLOGFILE);
}