package JobCenter::Api::JsonRpc2;

use strict;
use warnings;
use 5.10.0;

#
# Mojo's default reactor uses EV, and EV does not play nice with signals
# without some handholding. We either can try to detect EV and do the
# handholding, or try to prevent Mojo using EV.
#
BEGIN {
	$ENV{'MOJO_REACTOR'} = 'Mojo::Reactor::Poll';
}

# mojo
use Mojo::Base 'Mojo::EventEmitter';
use Mojo::IOLoop;
#use Mojo::JSON qw(decode_json encode_json);
use Mojo::Log;
use Mojo::Pg;

# standard
use Cwd qw(realpath);
use Data::Dumper;
use File::Basename;
use FindBin;
use IO::Pipe;
use Scalar::Util qw(refaddr);

# cpan
use Config::Tiny;
use JSON::MaybeXS;

use JSON::RPC2::TwoWay;

# JobCenter
use JobCenter::Api::Auth;
use JobCenter::Api::Client;
use JobCenter::Api::Job;
use JobCenter::Api::Task;
use JobCenter::Api::WorkerAction;
use JobCenter::Util;

has [qw(
	actionnames
	apiname
	auth
	cfg
	clients
	daemon
	debug
	listenstrings
	log
	pg
	pid_file
	ping
	server
	rpc
	tasks
	timeout
	tmr
)];

sub new {
	my ($class, %args) = @_;
	my $self = $class->SUPER::new();

	my $cfg;
	if ($args{cfgpath}) {
		$cfg = Config::Tiny->read($args{cfgpath});
		die 'failed to read config ' . $args{cfgpath} . ': ' . Config::Tiny->errstr unless $cfg;
	} else {
		die 'no cfgpath?';
	}

	my $apiname = ($args{apiname} || fileparse($0)) . " [$$]";
	my $daemon = $args{daemon} // 0; # or 1?
	my $debug = $args{debug} // 0; # or 1?
	my $log = $args{log} // Mojo::Log->new();
	$log->path(realpath("$FindBin::Bin/../log/$apiname.log")) if $daemon;

	my $pid_file = $cfg->{pid_file} // realpath("$FindBin::Bin/../log/$apiname.pid");
	die "$apiname already running?" if $daemon and check_pid($pid_file);

	# make our clientname the application_name visible in postgresql
	$ENV{'PGAPPNAME'} = $apiname;
	my $pg = Mojo::Pg->new(
		'postgresql://'
		. $cfg->{api}->{user}
		. ':' . $cfg->{api}->{pass}
		. '@' . $cfg->{pg}->{host}
		. ':' . $cfg->{pg}->{port}
		. '/' . $cfg->{pg}->{db}
	) or die 'no pg?';

	$pg->on(connection => sub { my ($e, $dbh) = @_; $log->debug("pg: new connection: $dbh"); });

	my $rpc = JSON::RPC2::TwoWay->new(debug => $debug) or die 'no rpc?';

	$rpc->register('announce', sub { $self->rpc_announce(@_) }, non_blocking => 0, state => 'auth');
	$rpc->register('create_job', sub { $self->rpc_create_job(@_) }, non_blocking => 1, state => 'auth');
	$rpc->register('get_job_status', sub { $self->rpc_get_job_status(@_) }, non_blocking => 1, state => 'auth');
	$rpc->register('get_task', sub { $self->rpc_get_task(@_) }, non_blocking => 1, state => 'auth');
	$rpc->register('hello', sub { $self->rpc_hello(@_) }, non_blocking => 1);
	$rpc->register('task_done', sub { $self->rpc_task_done(@_) }, notification => 1, state => 'auth');
	$rpc->register('withdraw', sub { $self->rpc_withdraw(@_) }, state => 'auth');

	my $serveropts = { port => $cfg->{api}->{listenport} };
	if ($cfg->{api}->{tls_key}) {
		$serveropts->{tls} = 1;
		$serveropts->{tls_key} = $cfg->{api}->{tls_key};
		$serveropts->{tls_cert} = $cfg->{api}->{tls_cert};
	}

	my $server = Mojo::IOLoop->server(
		$serveropts => sub {
			my ($loop, $stream, $id) = @_;
			my $client = JobCenter::Api::Client->new($rpc, $stream, $id);
			$client->on(close => sub { $self->_disconnect($client) });
		}
	) or die 'no server?';

	my $auth = JobCenter::Api::Auth->new(
		$cfg, 'api|auth',
	) or die 'no auth?';

	# keep sorted
	#$self->cfg($cfg);
	$self->{actionnames} = {};
	$self->{auth} = $auth;
	$self->{cfg} = $cfg;
	$self->{apiname} = $apiname;
	$self->{daemon} = $daemon;
	$self->{debug} = $debug;
	$self->{listenstrings} = {};
	$self->{log} = $log;
	$self->{pg} = $pg;
	$self->{pid_file} = $pid_file if $daemon;
	$self->{ping} = $args{ping} || 60;
	$self->{server} = $server;
	$self->{rpc} = $rpc;
	$self->{tasks} = {};
	$self->{timeout} = $args{timeout} // 60; # 0 is a valid timeout?

	# add a catch all error handler..
	$self->catch(sub { my ($self, $err) = @_; warn "This looks bad: $err"; });

	return $self;
}

sub work {
	my ($self) = @_;
	if ($self->daemon) {
		daemonize();
	}

	# set up a connection to test things
	# this also means that our first pg connection is only used for
	# notifications.. this seems to save some memory on the pg side
	$self->pg->pubsub->listen($self->apiname, sub {
		say 'ohnoes!';
		exit(1);
	});

	$self->log->debug('JobCenter::Api::JsonRpc starting work');
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
	#my $reactor = Mojo::IOLoop->singleton->reactor;
	#$reactor->{running}++;
	#while($reactor->{running}) {
	#	$reactor->one_tick();
	#}
	$self->log->debug('JobCenter::Api::JsonRpc done?');

	return 0;
}

sub _disconnect {
	my ($self, $client) = @_;
	$self->log->info('oh my.... ' . ($client->who // 'somebody') . ' disonnected..');
	return unless $client->who;

	my @actions = keys %{$client->actions};
	
	for my $a (@actions) {
		$self->log->debug("withdrawing $a");
		# hack.. make a _withdraw for this..?
		$self->rpc_withdraw($client->con, {actionname => $a});
	}
}

sub rpc_hello {
	my ($self, $con, $args, $rpccb) = @_;
	my $client = $con->owner;
	my $who = $args->{who} or die "no who?";
	my $method = $args->{method} or die "no method?";
	my $token = $args->{token} or die "no token?";

	$self->auth->authenticate($who, $method, $token, sub {
		my ($res, $msg) = @_;
		if ($res) {
			$self->log->debug("hello from $who succeeded: method $method msg $msg");
			$client->who($who);
			$con->state('auth');
			$rpccb->(JSON->true, "welcome to the clientapi $who!");
		} else {
			$self->log->debug("hello failed for $who: method $method msg $msg");
			$con->state(undef);
			# close the connecion after sending the response
			Mojo::IOLoop->next_tick(sub {
				$client->close;
			});
			$rpccb->(JSON->false, 'you\'re not welcome!');
		}
	});
}

sub rpc_create_job {
	my ($self, $con, $i, $rpccb) = @_;
	my $client = $con->owner;
	#$self->log->debug('create_job: ' . Dumper(\@_));
	my $wfname = $i->{wfname} or die 'no workflowname?';
	my $inargs = $i->{inargs} // '{}';
	my $vtag = $i->{vtag};
	my $timeout = $i->{timeout} // 60;
	my $impersonate = $client->who;
	my $cb = sub {
		my ($job_id, $outargs) = @_;
		$con->notify('job_done', {job_id => $job_id, outargs => $outargs});
	};

	die  'inargs should be a hashref' unless ref $inargs eq 'HASH';
	$inargs = encode_json($inargs);

	$self->log->debug("calling $wfname with '$inargs'" . (($vtag) ? " (vtag $vtag)" : ''));

	# create_job throws an error when:
	# - wfname does not exist
	# - inargs not valid
	Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			#($job_id, $listenstring) = @{
			$self->pg->db->dollar_only->query(
				q[select * from create_job(wfname := $1, args := $2, tag := $3, impersonate := $4)],
				$wfname,
				$inargs,
				$vtag,
				$impersonate,
				$d->begin
			);
		},
		sub {
			my ($d, $err, $res) = @_;

			if ($err) {
				$rpccb->(undef, $err);
				return;
			}
			my ($job_id, $listenstring) = @{$res->array};
			unless ($job_id) {
				$rpccb->(undef, "no result from call to create_job");
				return;
			}

			# report back to our caller immediately
			# this prevents the job_done notification overtaking the 
			# 'job created' result...
			$self->log->debug("created job_id $job_id listenstring $listenstring");
			$rpccb->($job_id, undef);

			my $job = JobCenter::Api::Job->new(
				cb => $cb,
				job_id => $job_id,
				inargs => $inargs,
				listenstring => $listenstring,
				tmr => Mojo::IOLoop->timer($timeout => sub {
						# request failed, cleanup
						#$self->pg->pubsub->unlisten($listenstring);
						$self->pg->pubsub->unlisten('job:finished');
						&$cb($job_id, {'error' => 'timeout'});
					}),
				vtag => $vtag,
				wfname => $wfname,
			);

			#$self->pg->pubsub->listen($listenstring, sub {
			# fixme: 1 central listen?
			$self->pg->pubsub->listen('job:finished', sub {
				my ($pubsub, $payload) = @_;
				return unless $job_id == $payload;
				local $@;
				eval { $self->_poll_done($job); };
				$self->log->debug("pubsub cb $@") if $@;
			});

			# do one poll first..
			$self->_poll_done($job);
		}
	)->catch(sub {
		my ($delay, $err) = @_;
		$rpccb->(undef, $err);
	});
}

sub _poll_done {
	my ($self, $job) = @_;
	Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			$self->pg->db->dollar_only->query(
				q[select * from get_job_status($1)],
				$job->job_id,
				$d->begin
			);
		},
		sub {
			my ($d, $err, $res) = @_;
			die $err if $err;
			my ($outargs) = @{$res->array};
			return unless $outargs;
			#$self->pg->pubsub->unlisten($job->listenstring);
			$self->pg->pubsub->unlisten('job:finished');
			Mojo::IOLoop->remove($job->tmr) if $job->tmr;
			$outargs = decode_json($outargs);
			$self->log->debug("calling cb $job->{cb} for job_id $job->{job_id} outargs $outargs");
			local $@;
			eval { $job->cb->($job->{job_id}, $outargs); };
			$self->log->debug("got $@ calling callback") if $@;
		}
	);
}


# fixme: reuse _poll_done?
sub rpc_get_job_status {
	my ($self, $con, $i, $rpccb) = @_;
	my $job_id = $i->{job_id} or die 'no job_id?';
	Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			$self->pg->db->dollar_only->query(
				q[select * from get_job_status($1)],
				$job_id,
				$d->begin
			);
		},
		sub {
			my ($d, $err, $res) = @_;
			if ($err) {
				$rpccb->(undef, $err);
				return;
			}
			my ($outargs) = @{$res->array};
			unless ($outargs) {
				$rpccb->(undef, undef);
				return;
			}
			$outargs = decode_json($outargs);
			$self->log->debug("got status for job_id $job_id outargs $outargs");
			$rpccb->($job_id, $outargs);
		}
	); # fixme: catch?
}

sub rpc_announce {
	my ($self, $con, $i, $rpccb) = @_;
	my $client = $con->owner;
	my $actionname = $i->{actionname} or die 'actionname required';
	my $slots      = $i->{slots} // 1;

	my ($worker_id, $listenstring);
	local $@;
	eval {
		# announce throws an error when:
		# - workername is not unique
		# - actionname does not exist
		# - worker has already announced action
		($worker_id, $listenstring) = @{$self->pg->db->dollar_only->query(
			q[select * from announce($1, $2, $3)],
			$client->who,
			$actionname,
			$client->who
		)->array};
		die "no result" unless $worker_id;
	};
	if ($@) {
		warn $@;
		return JSON->false, $@;
	}
	$self->log->debug("worker_id $worker_id listenstring $listenstring");

	unless ($self->listenstrings->{$listenstring}) {
		# oooh.. a totally new action
		$self->log->debug("listen $listenstring");
		$self->pg->pubsub->listen( $listenstring, sub {
			my ($pubsub, $payload) = @_;
			local $@;
			eval { $self->_task_ready($listenstring, $payload) };
			warn $@ if $@;
		});
		# assumption 1:1 relation actionname:listenstring
		$self->actionnames->{$actionname} = $listenstring;
		$self->listenstrings->{$listenstring} = [];
	}		

	my $wa = JobCenter::Api::WorkerAction->new(
		actionname => $actionname,
		client => $client,
		listenstring => $listenstring,
		slots => $slots,
		used => 0,
	);

	$client->worker_id($worker_id);
	$client->actions->{$actionname} = $wa;
	# note that this client is interested in this listenstring
	push @{$self->listenstrings->{$listenstring}}, $wa;

	# set up a ping timer to the client after the first succesfull announce
	unless ($client->tmr) {
		$client->{tmr} = Mojo::IOLoop->recurring( $client->ping, sub { $self->_ping($client) } );
	}
	return JSON->true, 'success';
}

sub rpc_withdraw {
	my ($self, $con, $i, $rpccb) = @_;
	my $client = $con->owner;
	my $actionname = $i->{actionname} or die 'actionname required';
	# find listenstring by actionname

	my $wa = $client->actions->{$actionname} or die "unknown actionname";
	# remove this action from the clients action list
	delete $client->actions->{$actionname};

	my $listenstring = $wa->listenstring or die "unknown listenstring";

	my ($res) = $self->pg->db->query(
			q[select withdraw($1, $2)],
			$client->who,
			$actionname
		)->array;
	die "no result" unless $res and @$res;
	
	# now remove this workeraction from the listenstring workeraction list
	my $l = $self->listenstrings->{$listenstring};
	my @idx = grep { refaddr $$l[$_] == refaddr $wa } 0..$#$l;
	splice @$l, $_, 1 for @idx;

	# delete if the listenstring client list is now empty
	unless (@$l) {
		delete $self->listenstrings->{$listenstring};
		delete $self->actionnames->{$actionname};
		$self->pg->pubsub->unlisten($listenstring);
		$self->log->debug("unlisten $listenstring");
	}		

	if (not $client->actions and $client->tmr) {
		# cleanup ping timer if client has no more actions
		$self->log->debug("remove tmr $client->{tmr}");
		Mojo::IOLoop->remove($client->tmr);
		delete $client->{tmr};
	}

	return 1;
}

sub _ping {
	my ($self, $client) = @_;
	my $tmr;
	Mojo::IOLoop->delay->steps(sub {
		my $d = shift;
		my $e = $d->begin;
		$tmr = Mojo::IOLoop->timer(3 => sub { $e->(@_, 'timeout') } );
		$client->con->call('ping', {}, sub { $e->($client, @_) });
	},
	sub {
		my ($d, $e, $r) = @_;
		#print 'got ', Dumper(\@_);
		if ($e and $e eq 'timeout') {
			$self->log->info('uhoh, ping timeout for ' . $client->who);
			Mojo::IOLoop->remove($client->id); # disconnect
		} else {
			if ($e) {
				$self->log->debug("'got $e->{message} ($e->{code}) from $client->{who}");
				return;
			}
			$self->log->debug('got ' . $r . ' from ' . $client->who . ' : ping(' . $client->worker_id . ')');
			Mojo::IOLoop->remove($tmr);
			$self->pg->db->query(q[select ping($1)], $client->worker_id, $d->begin);
		}
	});
}


# not a method!
sub _rot {
	my ($l) = @_;
	my $e = shift @$l;
        push @$l, $e;
        return $e;
}

sub _task_ready {
	my ($self, $listenstring, $job_id) = @_;
	
	$self->log->debug("got notify $listenstring for $job_id");
	my $l = $self->listenstrings->{$listenstring};
	return unless $l; # should not happen?

	_rot($l); # rotate listenstrings list (list of workeractions)
	my $wa;
	for (@$l) { # now find a worker with a free slot
		die "no wa?" unless $_;
		$self->log->debug('worker ' . $_->client->worker_id . ' has ' . $_->used . ' of ' . $_->slots . ' used');
		if ($_->used < $_->slots) {
			$wa = $_;
			last;
		}
	}

	unless ($wa) {
		$self->log->debug("no free slots for $listenstring!?");
		# the maestro will bother us again later
		return;
	}

	$self->log->debug('sending task ready to worker ' . $wa->client->worker_id . ' for ' . $wa->actionname);

	$wa->client->con->notify('task_ready', {actionname => $wa->actionname, job_id => $job_id});

	my $tmr =  Mojo::IOLoop->timer(3 => sub { $self->_task_ready_next($job_id) } );

	my $task = JobCenter::Api::Task->new(
		actionname => $wa->actionname,
		#client => $client,
		job_id => $job_id,
		listenstring => $listenstring,
		tmr => $tmr,
		workeraction => $wa,
	);
	$self->{tasks}->{$job_id} = $task;
}

sub _task_ready_next {
	my ($self, $job_id) = @_;
	
	my $task = $self->{tasks}->{$job_id} or return; # die 'no task in _task_ready_next?';
	
	$self->log->debug("try next client for $task->{listenstring} for $task->{job_id}");
	my $l = $self->listenstrings->{$task->listenstring};

	return unless $l; # should not happen?

	_rot($l); # rotate listenstrings list (list of workeractions)
	my $wa;
	for (@$l) { # now find a worker with a free slot
		$self->log->debug('worker ' . $_->client->worker_id . ' has ' . $_->used . ' of ' . $_->slots . ' used');
		if ($_->used < $_->slots) {
			$wa = $_;
			last;
		}
	}

	unless ($wa) {
		$self->log->debug("no free slots for $task->{listenstring}!?");
		# the maestro will bother us again later
		return;
	}

	if (refaddr $wa == refaddr $task->workeraction) {
		# hmmm...
		return;
	}

	$wa->client->con->notify('task_ready', {actionname => $wa->actionname, job_id => $job_id});

	my $tmr =  Mojo::IOLoop->timer(3 => sub { $self->_task_ready_next($job_id) } );

	$task->update(
		#client => $client,
		tmr => $tmr,
		workeraction => $wa,
		#job_id => $job_id,
	);
}

sub rpc_get_task {
	my ($self, $con, $i, $rpccb) = @_;
	my $client = $con->owner;
	my $workername = $client->who;
	my $actionname = $i->{actionname};
	my $job_id = $i->{job_id};
	$self->log->debug("get_task: workername $workername, actioname $actionname, job_id $job_id");

	my $task = delete $self->{tasks}->{$job_id};
	unless ($task) {
		$rpccb->();
		return;
	}

	Mojo::IOLoop->remove($task->tmr) if $task->tmr;
	
	#local $SIG{__WARN__} = sub {
	#	$self->log->debug($_[0]);
	#};

	Mojo::IOLoop->delay->steps(
		sub {
			my $d = shift;
			$self->pg->db->dollar_only->query(
				q[select * from get_task($1, $2, $3)],
				$workername, $actionname, $job_id,
				$d->begin
			);
		},
		sub {
			my ($d, $err, $res) = @_;
			if ($err) {
				$self->log->error("get_task threw $err");
				$rpccb->();
				return;
			}
			my ($cookie, $inargs) = @{$res->array};
			unless ($cookie) {
				$rpccb->();
			}

			$self->log->debug("cookie $cookie inargs $inargs");
			$inargs = decode_json( $inargs ); # unless $self->json;

			my $tmr =  Mojo::IOLoop->timer($self->timeout => sub { $self->_task_timeout($cookie) } );

			$task->update(
				cookie => $cookie,
				inargs => $inargs,
				tmr => $tmr,
			);
			$task->workeraction->{used}++;
			# ugh.. what a hack
			$self->{tasks}->{$cookie} = $task;

			$rpccb->($cookie, $inargs);
		}
	); # catch?
}

sub rpc_task_done {
	#my ($self, $task, $outargs) = @_;
	my ($self, $con, $i, $rpccb) = @_;
	my $client = $con->owner;
	my $cookie = $i->{cookie} or die 'no cookie?';
	my $outargs = $i->{outargs} or die 'no outargs?';

	my $task = delete $self->{tasks}->{$cookie};
	return unless $task; # really?	
	Mojo::IOLoop->remove($task->tmr) if $task->tmr;
	$task->workeraction->{used}--; # done..

	local $@;
	eval {
		$outargs = encode_json( $outargs );
	};
	$outargs = encode_json({'error' => 'cannot json encode outargs: ' . $@}) if $@;
	#$self->log->debug("outargs $outargs");
	eval {
		$self->pg->db->dollar_only->query(q[select task_done($1, $2)], $cookie, $outargs, sub { 1; } );
	};
	$self->log->debug("task_done got $@") if $@;
	$self->log->debug("worker $client->{who} done with action $task->{actionname} for job $task->{job_id} outargs $outargs\n");
	return;
}

sub _task_timeout {
	my ($self, $cookie) = @_;
	my $task = delete $self->{tasks}->{$cookie};
	return unless $task; # really?
	$task->workeraction->{used}++; # done..

	my $outargs = encode_json({'error' => 'timeout after ' . $self->timeout . ' seconds'});
	eval {
		$self->pg->db->dollar_only->query(q[select task_done($1, $2)], $cookie, $outargs, sub { 1; } );
	};
	$self->log->debug("task_done got $@") if $@;
	$self->log->debug("timeout for action $task->{actionname} for job $task->{job_id}");
}

1;