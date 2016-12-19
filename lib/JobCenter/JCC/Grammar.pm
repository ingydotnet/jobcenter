package JobCenter::JCC::Grammar;
use 5.10.0;
use Pegex::Base;
use base 'Pegex::Base';
extends 'Pegex::Grammar';

has indent => [];
has tabwidth => 8;
 
my $EOL = qr/\r?\n/;
my $EOD = qr/(?:$EOL)?(?=\z|\.\.\.\r?\n|\-\-\-\r?\n)/;
my $SPACE = qr/ /;
my $NONSPACE = qr/(?=[^\s\#])/;
my $NOTHING = qr//;


# based on https://metacpan.org/source/INGY/YAML-Pegex-0.0.17/lib/YAML/Pegex/Grammar.pm

# check that the indentation level increases by one step but do not consume
sub rule_block_indent {
	my ($self, $parser, $buffer, $pos) = @_;
	return if $pos >= length($$buffer);
	my $indents = $self->{indent};
	my $tabwidth = $self->{tabwidth};
	pos($$buffer) = $pos;
	my $len = @$indents ? $indents->[-1] + 1 : 1;
	say "need indent of at least $len";
	my ($indent) = $$buffer =~ /\G^(\s+)\S/cgm or return;
	# expand tabs
	$indent =~ s/\t/' ' x $tabwidth/eg; # todo: optimize?
	$indent = length($indent);
	say "found indent of ", $indent;
	return if $indent < $len;
	push @$indents, $indent;
	say "indents now ", join(', ', @$indents);
	return $parser->match_rule($pos);
}
 
# consume indentation and check that the indentation level is still the same
sub rule_block_ondent {
	my ($self, $parser, $buffer, $pos) = @_;
	my $indents = $self->{indent};
	my $tabwidth = $self->{tabwidth};
	my $len = $indents->[-1];
	say "need indent of $len";
	pos($$buffer) = $pos;
	my ($indent) = $$buffer =~ /\G^(\s+)(?=\S)/cgm or return; # no indent no match
	# expand tabs
	$indent =~ s/\t/' ' x $tabwidth/eg;
	$indent = length($indent);
	return if $indent != $len;
	return $parser->match_rule(pos($$buffer));
}
 
# check that the indentation level decreases by one step but do not consume
sub rule_block_undent {
	my ($self, $parser, $buffer, $pos) = @_;
	my $indents = $self->{indent};
	return unless @$indents;
	my $tabwidth = $self->{tabwidth};
	my $len = $indents->[-1];
	say "need indent of less than $len";
	pos($$buffer) = $pos;
	my ($indent) = $$buffer =~ /(?:\G^(\s*)\S)|\z/cgm; # always matches?
	if ($indent) {
		# expand tabs
		$indent =~ s/\t/' ' x $tabwidth/eg;
		$indent = length($indent);
	} else {
		$indent = 0;
	}
	say "found indent of ", $indent;
	return unless $indent < $len;
	pop @$indents;
	return $parser->match_rule($pos);
}


has text =>  <<'EOT';
%grammar wfl
%version 0.0.1

jcl: .ignorable* ( +workflow | +action ) .ignorable*

# hack in action support
action: +action-type +workflow-name colon ( .ignorable | +in | +out )*

action-type: / ( 'action' | 'procedure' ) / __

workflow: / 'workflow' __ / +workflow-name colon ( .ignorable | +in | +out | +limits | +locks | +wfomap | +do )*

workflow-name: identifier

in: / 'in' <colon> / block-indent inout block-undent

out: / 'out' <colon> / block-indent inout block-undent

inout: ( iospec | .ignorable )*

iospec: block-ondent identifier __ identifier (__ / ('optional') / | __ literal)? / _ SEMI? _ /

limits: / 'limits' <colon> / block-indent ( limitspec | .ignorable)* block-undent

limitspec: block-ondent / ( 'max_depth' | 'max_steps' ) __ EQUAL __ / unsigned-integer

locks: / 'locks' <colon> / block-indent ( lockspec | .ignorable )* block-undent

lockspec: block-ondent identifier  __ ( identifier | / ( UNDER ) / ) (__ / ( 'inherit' | 'manual') / )*

wfomap: / 'wfomap' <colon> / assignments

do: / 'do' <colon> / block

block: block-indent block-body block-undent

block-body: (block-ondent statement | .ignorable)*

statement: 
#	.ignorable
	| +call
	| +case
	| +eval
	| +goto
	| +if
	| +label
	| +lock
	| +raise_error
	| +raise_event
	| +repeat
	| +return
	| +split
	| +subscribe
	| +try
	| +unlock
	| +unsubscribe
#	| wait_for_child
	| +wait_for_event
	| +while

#call: / 'call' __ / +call-name colon block-indent call-body block-undent

#call-name: identifier

#call-body:  (+imap | +omap | .ignorable )*

#imap: block-ondent / 'imap' <colon> / assignments

#omap: block-ondent / 'omap' <colon> / assignments

call:
	/ 'call' __ / +call-name colon call-body

call-name: identifier

call-body: +imap block-ondent / 'into' <colon> / +omap

imap: assignments

omap: assignments

assignments: perl-block | native-assignments

native-assignments: block-indent ( assignment | magic-assignment | .ignorable )* block-undent

assignment: block-ondent lhs _ assignment-operator _ rhs / _ SEMI? _ /

magic-assignment: block-ondent / LANGLE / identifier / RANGLE /

lhs: ( / (ALPHA) DOT / )? varpart ( / DOT / varpart )*

assignment-operator: / ( EQUAL | DOT EQUAL | PLUS EQUAL | DASH EQUAL ) /

rhs: term ( rhs-operator term )*

term: +unop-term | plain-term

unop-term: unary-operator plain-term

plain-term: +functioncall | literal | +variable | +parented

parented: / LPAREN _ / rhs / _ RPAREN /

# fixme: do and/or belong in here?
#rhs-operator: / _ ( STAR STAR | STAR | SLASH | PERCENT | ' x ' | PLUS | DASH | DOT | AMP AMP | PIPE PIPE | SLASH SLASH | ' and ' | ' or ' ) _ / 

rhs-operator: / _ ( STAR STAR | STAR | SLASH SLASH | SLASH | PERCENT | 'x' | PLUS | DASH | DOT
	| LANGLE EQUAL | RANGLE EQUAL | LANGLE | RANGLE | 'lt'
	| 'gt' | 'le' | 'ge' | EQUAL EQUAL | BANG EQUAL | 'eq' | 'ne'
	| AMP AMP | PIPE PIPE | 'and' | 'or' ) _ /


unary-operator: / ( BANG | DASH | PLUS | 'not ' ) /

functioncall: identifier / LPAREN _ / ( funcarg ) / _ RPAREN /

funcarg: rhs ( _ ( COMMA | COLON ) _ rhs )*

case: / 'case' __ / +case-expression colon (+when | .ignorable)* case-else?

case-expression: ( perl-block | rhs )

when: block-ondent / 'when' __  / +case-label colon +block

case-label: identifier ( _ COMMA _ identifier )*

case-else: block-ondent +else

eval: / 'eval' <colon> / assignments

goto: / 'goto' __ / identifier

label: / 'label' __ / identifier

if: / 'if' _ / +condition colon +then elses?

then: block

elses: block-ondent ( +elsif | +else )

elsif: / 'elsif' __ / +condition colon +then elses?

else: / 'else' <colon> / block

lock: / 'lock' __ / identifier __ ( perl_block | rhs )

raise_error: / 'raise_error' <colon> / assignments

raise_event: / 'raise_event' <colon> / assignments

repeat: / 'repeat' colon / +block / __ 'until' __ / +condition

return: / ('return') /

split: / 'split' / colon block-indent callflow+ block-undent

callflow: block-ondent / 'callflow' __ / +call-name colon call-body

subscribe: / 'subscribe' <colon> / assignments

try: / 'try' / colon +try-block block-ondent / 'catch' / colon +catch-block

try-block: block

catch-block: block

unlock: / 'unlock' __ / identifier __ ( perl_block | rhs )

unsubscribe: / 'unsubscribe' <colon> / assignments

wait_for_event: / 'wait_for_event' / colon call-body

while: / 'while' __ / +condition colon +block

condition: perl-block | rhs
#condition: perl-block | boolean-expression

#boolean-expression: term ( boolean-operator term )*

#boolean-operator: / _ ( LANGLE EQUAL | RANGLE EQUAL | LANGLE | RANGLE | ' lt '|
#	' gt ' | ' le ' | ' ge ' | EQUAL EQUAL | BANG EQUAL | ' eq ' | ' ne '
#	| AMP AMP | PIPE PIPE | SLASH SLASH | ' and ' | ' or ' ) _ /

variable: / ( ALPHA ) DOT / varpart ( / DOT / varpart )*

varpart: identifier ( / LSQUARE <integer> LSQUARE / )?

literal: +number | +boolean | +single-quoted-string | +double-quoted-string | +null

null: / ('NULL'|'null') /

number: / ( (:'0'[xX] HEX+) | (:'-'? DIGIT* DOT DIGIT+) | (:'-'? DIGIT+) ) /

boolean: / ('TRUE'|'FALSE'|'true'|'false') /

ignorable: blank-line | multi-line-comment | single-line-comment
blank-line: / _ EOL /
multi-line-comment: / _ HASH LSQUARE ( ANY*? ) LSQUARE ALL*? HASH RSQUARE \1 RSQUARE /
single-line-comment: / _ HASH ANY* EOL /

identifier: bare-identifier | string

bare-identifier: /( ALPHA WORD* )/

string: single-quoted-string | double-quoted-string

single_quoted_string:
    /(:
        SINGLE
        ((:
            [^ BREAK BACK SINGLE] |
            BACK SINGLE |
            BACK BACK
        )*?)
        SINGLE
    )/

double_quoted_string:
    /(:
        DOUBLE
        ((:
            [^ BREAK BACK DOUBLE] |
            BACK DOUBLE |
            BACK BACK |
            BACK escape
        )*?)
        DOUBLE
    )/

escape: / [0nt] /

perl-block: / _ LSQUARE ( ANY *? ) LSQUARE ( (?: (?! RSQUARE RSQUARE ) ALL )*? ) RSQUARE \1 RSQUARE EOL? /

integer: / ( DASH? DIGIT+ ) /

unsigned-integer: / ( DIGIT+ ) /

colon: / _ COLON _ EOL /

# normally _ and __ matches newlines to, we don't want that?
_: / BLANK* /
__: / BLANK+ /

EOT

sub foo {
	say 'foo!';
}

1;