package JobCenter::Api::WorkerAction;
use Mojo::Base -base;

has [qw(actionname client filter listenstring slots used workername)];

sub update {
	my ($self, %attr) = @_;
	my ($k,$v);
	while (($k, $v) = each %attr) {
		$self->{$k} = $v;
	}
	return $self;
}

#sub DESTROY {
#	my $self = shift;
#	say 'destroying ', $self;
#}

1;
