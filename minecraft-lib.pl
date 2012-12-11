# Functions for editing the minecraft config
#
# XXX java param options
# XXX plugins?
# XXX world reset

BEGIN { push(@INC, ".."); };
use strict;
use warnings;
use WebminCore;
use Time::Local;
&init_config();
our ($module_root_directory, %text, %gconfig, $root_directory, %config,
     $module_name, $remote_user, $base_remote_user, $gpgpath,
     $module_config_directory, @lang_order_list, @root_directories);
our $history_file = "$module_config_directory/history.txt";

# check_minecraft_server()
# Returns an error message if the Minecraft server is not installed
sub check_minecraft_server
{
-d $config{'minecraft_dir'} ||
	return &text('check_edir', $config{'minecraft_dir'});
my $jar = $config{'minecraft_jar'} ||
	  $config{'minecraft_dir'}."/"."minecraft_server.jar";
-r $jar ||
	return &text('check_ejar', $jar);
&has_command($config{'java_cmd'}) ||
	return &text('check_ejava', $config{'java_cmd'});
return undef;
}

# is_minecraft_server_running()
# If the minecraft server is running, return the PID
sub is_minecraft_server_running
{
&foreign_require("proc");
my @procs = &proc::list_processes();
my $jar = $config{'minecraft_jar'} ||
	  $config{'minecraft_dir'}."/"."minecraft_server.jar";
my $shortjar = $jar;
$shortjar =~ s/^.*\///;
foreach my $p (@procs) {
	if ($p->{'args'} =~ /\Q$config{'java_cmd'}\E.*(\Q$jar\E|\Q$shortjar\E)/) {
		return $p->{'pid'};
		}
	}
return undef;
}

# get_minecraft_config()
# Parses the config into an array ref of hash refs
sub get_minecraft_config
{
my @rv;
my $fh = "CONFIG";
my $lnum = 0;
&open_readfile($fh, $config{'minecraft_dir'}."/server.properties") ||
	return [ ];
while(<$fh>) {
	s/\r|\n//g;
	s/#.*$//;
	if (/^([^=]+)=(.*)/) {
		push(@rv, { 'name' => $1,
			    'value' => $2,
			    'line' => $lnum });
		}
	$lnum++;
	}
close($fh);
return \@rv;
}

# get_start_command()
# Returns a command to start the server
sub get_start_command
{
my $jar = $config{'minecraft_jar'} ||
	  $config{'minecraft_dir'}."/"."minecraft_server.jar";
my $ififo = &get_input_fifo();
my $rv = "(test -e ".$ififo." || mkfifo ".$ififo.") ; ".
	 "cd ".$config{'minecraft_dir'}." && ".
	 "(tail -f ".$ififo." | ".
	 &has_command($config{'java_cmd'})." ".
	 $config{'java_args'}." ".
	 " -jar ".$jar." nogui ".
	 $config{'jar_args'}." ".
	 ">> server.out 2>&1 )";
return $rv;
}

sub get_output_fifo
{
return $config{'minecraft_dir'}."/output.fifo";
}

sub get_input_fifo
{
return $config{'minecraft_dir'}."/input.fifo";
}

# start_minecraft_server()
# Launch the minecraft server in the background
sub start_minecraft_server
{
my $cmd = &get_start_command();
&system_logged("$cmd &");
sleep(1);
if (!&is_minecraft_server_running()) {
	my $out = &backquote_command(
		"tail -2 ".$config{'minecraft_dir'}."/server.out");
	return $out || "Unknown error - no output produced";
	}
return undef;
}

# stop_minecraft_server()
# Kill the server, if running
sub stop_minecraft_server
{
my $pid = &is_minecraft_server_running();
$pid || return "Not running!";

# Try graceful shutdown
&send_server_command("stop");
for(my $i=0; $i<10; $i++) {
	last if (!&is_minecraft_server_running());
	sleep(1);
	}

# Clean kill
if (&is_minecraft_server_running()) {
	kill('TERM', $pid);
	for(my $i=0; $i<10; $i++) {
		last if (!&is_minecraft_server_running());
		sleep(1);
		}
	}

# Fatal kill
if (&is_minecraft_server_running()) {
	kill('KILL', $pid);
	}
return undef;
}

# send_server_command(command)
# Just sends a command to the server
sub send_server_command
{
my ($cmd) = @_;
my $ififo = &get_input_fifo();
my $fh = "FIFO";
&open_tempfile($fh, ">$ififo", 1, 1, 1);
&print_tempfile($fh, $cmd."\n");
&close_tempfile($fh);
}

# execute_minecraft_command(command)
# Run a command, and return output from the server log
sub execute_minecraft_command
{
my ($cmd) = @_;
my $logfile = $config{'minecraft_dir'}."/server.log";
my $fh = "LOG";
&open_readfile($fh, $logfile);
seek($fh, 0, 2);
my $pos = tell($fh);
&send_server_command($cmd);
for(my $i=0; $i<100; $i++) {
	select(undef, undef, undef, 0.1);
	my @st = stat($logfile);
	last if ($st[7] > $pos);
	}
my $out;
while(<$fh>) {
	$out .= $_;
	}
close($fh);
return wantarray ? split(/\r?\n/, $out) : $out;
}

# get_command_history()
# Returns the history of commands run
sub get_command_history
{
my $lref = &read_file_lines($history_file);
return @$lref;
}

# save_command_history(&commands)
sub save_command_history
{
my ($cmds) = @_;
my $lref = &read_file_lines($history_file);
@$lref = @$cmds;
&flush_file_lines($history_file);
}

# list_connected_players()
# Returns a list of players currently online
sub list_connected_players
{
my @out = &execute_minecraft_command("/list");
my @rv;
foreach my $l (@out) {
	if ($l =~ /\[INFO\]\s+(\S+)$/) {
		push(@rv, $1);
		}
	}
return @rv;
}

# get_login_logout_times(player)
# Returns the last login IP, time, X, Y, Z and logout time (if any)
sub get_login_logout_times
{
my ($name) = @_;
my ($ip, $intime, $xx, $yy, $zz, $outtime);
my $logfile = $config{'minecraft_dir'}."/server.log";
my $fh = "TAIL";
&open_execute_command($fh, "tail -10000 $logfile", 1, 1);
while(<$fh>) {
	if (/^(\d+)\-(\d+)\-(\d+)\s+(\d+):(\d+):(\d+)\s+\[\S+\]\s+(.*)/) {
		my ($y, $mo, $d, $h, $m, $s, $msg) =($1, $2, $3, $4, $5, $6, $7);
		if ($msg =~ /^\Q$name\E\[.*\/([0-9\.]+):(\d+)\]\s+logged\s+in.*\((\-?[0-9\.]+),\s+(\-?[0-9\.]+),\s+(\-?[0-9\.]+)\)/) {
			# Login message
			$ip = $1;
			($xx, $yy, $zz) = ($3, $4, $5);
			$intime = &parse_log_time($y, $m, $d, $h, $mo, $s);
			}
		elsif ($msg =~ /^\Q$name\E\s+lost/) {
			# Logout message
			$outtime = &parse_log_time($y, $m, $d, $h, $mo, $s);
			}
		}
	}
close($fh);
return ( $ip, $intime, $xx, $yy, $zz, $outtime );
}

sub parse_log_time
{
my ($y, $m, $d, $h, $mo, $s) = @_;
return timelocal($s, $m, $h, $d, $mo-1, $y-1900);
}

# item_chooser_button(fieldname)
sub item_chooser_button
{
my ($field) = @_;
return "<input type=button onClick='ifield = document.forms[0].$field; chooser = window.open(\"item_chooser.cgi?item=\"+escape(ifield.value), \"chooser\", \"toolbar=no,menubar=no,scrollbars=yes,width=400,height=600\"); chooser.ifield = ifield; window.ifield = ifield' value=\"...\">\n";
}

# list_minecraft_items()
# Returns a list of hash refs with id and name keys
# CSV generated with :
# wget -O - http://minecraft-ids.grahamedgecombe.com/ | grep /items/ | perl -ne 's/.*items.([0-9:]+)">([^<]+)<.*/$1,$2/; print ' > items.csv
sub list_minecraft_items
{
my $fh = "ITEMS";
&open_readfile($fh, "$module_root_directory/items.csv");
my @rv;
while(<$fh>) {
	s/\r|\n//g;
	my ($id, $name) = split(/,/, $_);
	push(@rv, { 'id' => $id,
		    'name' => $name });
	}
close($fh);
return @rv;
}

# list_banned_players()
# Returns a list of players who are banned
sub list_banned_players
{
my @out = &execute_minecraft_command("/banlist");
my @rv;
foreach my $l (@out) {
	if ($l =~ /\[INFO\]\s+(\S+)$/) {
		push(@rv, $1);
		}
	}
return @rv;
}

# list_whitelisted_players()
# Returns a list of players who are whitelisted
sub list_whitelisted_players
{
my @out = &execute_minecraft_command("/whitelist");
my @rv;
foreach my $l (@out) {
	if ($l =~ /\[INFO\]\s+(\S+)$/) {
		push(@rv, $1);
		}
	}
return @rv;
}

# list_whitelist_users()
# Returns a list of usernames on the whitelist
sub list_whitelist_users
{
my $lref = &read_file_lines($config{'minecraft_dir'}.'/white-list.txt', 1);
return @$lref;
}

# save_whitelist_users(&users)
# Update the usernames on the whitelist
sub save_whitelist_users
{
my ($users) = @_;
my $lref = &read_file_lines($config{'minecraft_dir'}.'/white-list.txt');
@$lref = @$users;
&flush_file_lines($config{'minecraft_dir'}.'/white-list.txt');
}

# list_op_users()
# Returns a list of usernames on the operator list
sub list_op_users
{
my $lref = &read_file_lines($config{'minecraft_dir'}.'/ops.txt', 1);
return @$lref;
}

# save_op_users(&users)
# Update the usernames on the operator list
sub save_op_users
{
my ($users) = @_;
my $lref = &read_file_lines($config{'minecraft_dir'}.'/ops.txt');
@$lref = @$users;
&flush_file_lines($config{'minecraft_dir'}.'/ops.txt');
}



1;
