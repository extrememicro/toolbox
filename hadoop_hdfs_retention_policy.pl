#!/usr/bin/perl -T
#
#  Author: Hari Sekhon
#  Date: 2013-01-14 20:50:13 +0000 (Mon, 14 Jan 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#

$DESCRIPTION = "Prints files from one or more Hadoop HDFS directory trees (default /tmp) that are older than the given Days Hours Mins. Deletes files if specifying --rm

Credit to my old colleague Rob Dawson @ Specific Media for giving me this idea during lunch";

$VERSION = "0.6.0";

use strict;
use warnings;
use Time::Local;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils qw/:DEFAULT :regex/;

$ENV{"PATH"} .= ":/opt/hadoop/bin:/usr/local/hadoop/bin";

my $default_hadoop_bin = "hadoop";
my $hadoop_bin = $default_hadoop_bin;

my $DEFAULT_PATH = "/tmp";
my $path; # don't set this, need to check if user did or used @ARGV

my $days  = 0;
my $hours = 0;
my $mins  = 0;
my $include;
my $exclude;
my $skipTrash = "";
my $rm    = 0;
my $batch = 0;

set_timeout_max(86400);    # 1 day max -t timeout
set_timeout_default(1800); # 30 mins. hadoop fs -lsr /tmp took 6 minutes to list 1720943 files/dirs on my test cluster!

my %months = (
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
);

%options = (
    "d|days=i"      =>  [ \$days,       "Number of days after which to delete files" ],
    "H|hours=i"     =>  [ \$hours,      "Number of hours after which to delete files" ],
    "m|mins=i"      =>  [ \$mins,       "Number of minutes after which to delete files" ],
    "p|path=s"      =>  [ \$path,       "Path for which to remove old files (default: $DEFAULT_PATH)" ],
    "i|include=s"   =>  [ \$include,    "Include Regex of files, for optional filtering" ],
    "e|exclude=s"   =>  [ \$exclude,    "Exclude Regex of files, optional, takes priority over --include" ],
    "rm"            =>  [ \$rm,         "Actually launch the hadoop fs -rm commands on the files, by default this script only prints the hadoop fs -rm commands. WARNING: only use this switch after you have checked what the list of files to be removed is, otherwise you may lose data" ],
    "skipTrash"     =>  [ \$skipTrash,  "Skips moving files to HDFS Trash, reclaims space immediately" ],
    "hadoop-bin=s"  =>  [ \$hadoop_bin, "Path to 'hadoop' command if not in \$PATH" ],
    "b|batch=s"     =>  [ \$batch,      "Batch the deletes in groups of N files for efficiency (max 100)" ],
);
@usage_order = qw/days hours mins path include exclude rm skipTrash batch hadoop-bin/;
get_options();

my $print_only = 1;
if ($rm and not $debug){
    $print_only = 0; # actually run the hadoop fs -rm command instead of just echo'ing it out
}
$skipTrash = "-skipTrash" if $skipTrash;

$days    = validate_float($days,  0, 3650, "days");
$hours   = validate_float($hours, 0, 23,   "hours");
$mins    = validate_float($mins,  0, 59,   "mins");
my $max_age_secs = ($days * 86400) + ($hours * 3600) + ($mins * 60);
usage "must specify a total max age > 5 minutes" if ($max_age_secs < 300);
my @paths = ();
push(@paths, validate_filename($path, 0, "path")) if defined($path); # because validate_dir[ectory] checks the directory existance on the local filesystem
foreach(@ARGV){
    push(@paths, validate_filename($_, 0, "path") );
}
if(@paths){
    $path = "'" . join("' '", uniq_array @paths) . "'";
} else {
    $path = "'$DEFAULT_PATH'";
}
if(defined($include)){
    $include     = validate_regex($include, "include");
    $include     = qr/$include/o;
}
if(defined($exclude)){
    $exclude     = validate_regex($exclude, "exclude");
    $exclude     = qr/$exclude/o;
}
$hadoop_bin  = which($hadoop_bin, 1);
$hadoop_bin  =~ /\b\/?hadoop$/ or die "invalid hadoop program '$hadoop_bin' given, should be called hadoop!\n";
$batch       = validate_int($batch, 0, 100, "batch size");
vlog_options "rm",          $rm        ? "true" : "false";
vlog_options "skipTrash",   $skipTrash ? "true" : "false";
vlog_options "hadoop path", $hadoop_bin;
vlog2;

set_timeout();

my $cmd   = "hadoop fs -ls -R $path"; # is quoted above when processing $path or @paths;
my $fh    = cmd("$cmd | ") or die "ERROR: $? returned from \"$cmd\" command: $!\n";
my @files = ();
my $now   = time || die "Failed to get epoch timestamp\n";
my $file_count     = 0;
my $files_removed  = 0;
my $excluded_count = 0;
my $script_excluded_count = 0;
while (<$fh>){
    print "output: $_" if $verbose >= 3;
    chomp;
    my $line = $_;
    $line =~ /^Found\s\d+\sitems/ and next;
    if($line =~ /^([d-])$rwxt_regex\s+(?:\d+|-)\s+\w+\s+\w+\s+\d+\s+(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})\s+($filename_regex)$/){
        my $dir      = $1;
        next if $dir eq "d"; # Not supporting dirs as there is no -rmdir and it would require a dangerous -rmr operation and should therefore be done by hand
        $file_count++;
        my $year     = $2;
        my $month    = $3;
        my $day      = $4;
        my $hour     = $5;
        my $min      = $6;
        my $filename = $7;
        $month = $months{$month} if grep { $month eq $_} keys %months;
        my $tstamp   = timelocal(0, $min, $hour, $day, $month-1, $year) || die "$progname: Failed to convert timestamp $year-$month-$day $hour:$min for comparison\n";
        if( ($now - $tstamp ) > $max_age_secs){
            if (defined($exclude) and $filename =~ $exclude){
                $excluded_count += 1;
                next;
            }
            # - Some additional safety stuff, do not mess with /tmp/mapred or /hbase !!!!
            # - or .Trash...
            # - or now /solr has been added...
            # - oh and I should probably omit the CM canary files given I work for Cloudera now...
            # - Also, omitting the Hive warehouse directory since removing Hive managed tables seems scary
            # - share/lib/ is under /user/oozie, don't remove that either
            # not anchoring /tmp intentionally since hadoop fs -ls ../../tmp results in ../../tmp and without anchor this will still exclude
            if ($filename =~ qr( 
                                    /tmp/mapred/ |
                                    /hbase/      |
                                    /solr/       |
                                    \.Trash/     |
                                    warehouse/   |
                                    share/lib/   |
                                    \.cloudera_health_monitoring_canary_files |
                                    ['"]
                                    )ix){
                $script_excluded_count++;
                next;
            }
            if(defined($include)){
                if($filename =~ $include){
                    push(@files, $filename);
                    $files_removed++;
                }
            } else {
                push(@files, $filename);
                $files_removed++;
            }
        }
    } else {
        warn "$progname: WARNING - failed to match line from hadoop output: \"$line\"\n";
    }
    if(@files and $batch < 2){
        $cmd = "hadoop fs -rm $skipTrash '" . join("' '", @files) . "'";
        if($print_only){
            print "$cmd\n";
        } else {
            system($cmd) and die "ERROR: $? returned from command \"$cmd\": $!\n";
        }
        @files = ();
    }
}
if(@files and $batch > 1){
    for(my $i=0; $i < scalar @files; $i += $batch){
        #print "total batch = @files\n";
        #print "batch 3 =  " . join(" -- ", @files[ $i .. $i+3 ]) . "\n";
        my $last_index = $i + $batch - 1;
        if($last_index >= scalar @files){
            $last_index = scalar(@files) - 1;
        }
        $cmd = "hadoop fs -rm $skipTrash '" . join("' '", @files[ $i .. $last_index ]) . "'";
        #vlog2 "checking getconf ARG_MAX to make sure this batch command isn't too big";
        my $ARG_MAX = `getconf ARG_MAX`;
        isInt($ARG_MAX) or code_error "failed to get ARG_MAX from 'getconf ARG_MAX', got a non-integer '$ARG_MAX'";
        if(length($cmd) < $ARG_MAX){
            #vlog2 "command length: " . length($cmd) . "  ARG_MAX: $ARG_MAX";
        } else {
            die "resulting hadoop fs -rm command length > operating system's ARG_MAX ($ARG_MAX). Review and reduce batch size if necessary, this may be caused by very long filenames coupled with large batch size.\n\nHere is the would-be command:\n\n$cmd";
        }
        print "file batch " . ($i+1) . " - " . ($last_index+1) . ":\n";
        if($print_only){
            print "$cmd\n";
        } else {
            system($cmd) and die "ERROR: $? returned from command \"$cmd\": $!\n";
        }
    }
}

plural $file_count;
$msg = "$progname Complete - %d file$plural checked, $excluded_count excluded, ";
$msg .= "$script_excluded_count hardcoded excluded for safety, " if $script_excluded_count;
plural $files_removed;
$msg .= "%d file$plural older than %s days %s hours %s mins " . ($print_only ? "" : "removed") . "\n";
printf($msg, $file_count, $files_removed, $days, $hours, $mins);