package Slim::Menu::YearInfo;

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Provides OPML-based extensible menu for year info
=head1 NAME

Slim::Menu::YearInfo

=head1 DESCRIPTION

Provides a dynamic OPML-based year info menu to all UIs and allows
plugins to register additional menu items.

=cut

use strict;

use base qw(Slim::Menu::Base);

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

my $log = logger('menu.yearinfo');

sub init {
	my $class = shift;
	$class->SUPER::init();
	
	Slim::Control::Request::addDispatch(
		[ 'yearinfo', 'items', '_index', '_quantity' ],
		[ 1, 1, 1, \&cliQuery ]
	);
	
	Slim::Control::Request::addDispatch(
		[ 'yearinfo', 'playlist', '_method' ],
		[ 1, 1, 1, \&cliQuery ]
	);
}

sub name {
	return 'YEAR_INFO';
}

##
# Register all the information providers that we provide.
# This order is defined at http://wiki.slimdevices.com/index.php/UserInterfaceHierarchy
#
sub registerDefaultInfoProviders {
	my $class = shift;
	
	$class->SUPER::registerDefaultInfoProviders();

	$class->registerInfoProvider( addyear => (
		menuMode  => 1,
		after    => 'top',
		func      => \&addYearEnd,
	) );

	$class->registerInfoProvider( addyearnext => (
		menuMode  => 1,
		after    => 'addyear',
		func      => \&addYearNext,
	) );


	$class->registerInfoProvider( playyear => (
		menuMode  => 1,
		after    => 'addyearnext',
		func      => \&playYear,
	) );


}

sub menu {
	my ( $class, $client, $url, $year, $tags ) = @_;
	$tags ||= {};

	# If we don't have an ordering, generate one.
	# This will be triggered every time a change is made to the
	# registered information providers, but only then. After
	# that, we will have our ordering and only need to step
	# through it.
	my $infoOrdering = $class->getInfoOrdering;

	
	# $remoteMeta is an empty set right now. adding to allow for parallel construction with trackinfo
	my $remoteMeta = {};

	# Function to add menu items
	my $addItem = sub {
		my ( $ref, $items ) = @_;
		
		if ( defined $ref->{func} ) {
			
			my $item = eval { $ref->{func}->( $client, $url, $year, $remoteMeta, $tags ) };
			if ( $@ ) {
				$log->error( 'Yearinfo menu item "' . $ref->{name} . '" failed: ' . $@ );
				return;
			}
			
			return unless defined $item;
			
			# skip jive-only items for non-jive UIs
			return if $ref->{menuMode} && !$tags->{menuMode};
			
			if ( ref $item eq 'ARRAY' ) {
				if ( scalar @{$item} ) {
					push @{$items}, @{$item};
				}
			}
			elsif ( ref $item eq 'HASH' ) {
				return if $ref->{menuMode} && !$tags->{menuMode};
				if ( scalar keys %{$item} ) {
					push @{$items}, $item;
				}
			}
			else {
				$log->error( 'Yearinfo menu item "' . $ref->{name} . '" failed: not an arrayref or hashref' );
			}				
		}
	};
	
	# Now run the order, which generates all the items we need
	my $items = [];
	
	for my $ref ( @{ $infoOrdering } ) {
		# Skip items with a defined parent, they are handled
		# as children below
		next if $ref->{parent};
		
		# Add the item
		$addItem->( $ref, $items );
		
		# Look for children of this item
		my @children = grep {
			$_->{parent} && $_->{parent} eq $ref->{name}
		} @{ $infoOrdering };
		
		if ( @children ) {
			my $subitems = $items->[-1]->{items} = [];
			
			for my $child ( @children ) {
				$addItem->( $child, $subitems );
			}
		}
	}
	
	return {
		name  => $year,
		type  => 'opml',
		items => $items,
	};
}


sub playYear {
	my ( $client, $url, $year, $remoteMeta, $tags) = @_;

	my $items = [];
	my $jive;
	
	my $play_string   = cstring($client, 'PLAY');

	my $actions = {
		go => {
			player => 0,
			cmd => [ 'playlistcontrol' ],
			params => {
				year => $year,
				cmd => 'load',
			},
			nextWindow => 'nowPlaying',
		},
		add => {
			player => 0,
			cmd => [ 'playlistcontrol' ],
			params => {
				year => $year,
				cmd => 'add',
			},
			nextWindow => 'parent',
		},
		'add-hold' => {
			player => 0,
			cmd => [ 'playlistcontrol' ],
			params => {
				year => $year,
				cmd => 'insert',
			},
			nextWindow => 'parent',
		},
	};
	$actions->{play} = $actions->{go};

	$jive->{actions} = $actions;

	push @{$items}, {
		type => 'text',
		name => $play_string,
		jive => $jive, 
	};
	
	return $items;
}

sub addYearEnd {
	my ( $client, $url, $year, $remoteMeta, $tags ) = @_;
	my $add_string   = cstring($client, 'ADD_TO_END');
	my $cmd = 'add';
	addYear( $client, $url, $year, $remoteMeta, $tags, $add_string, $cmd ); 
}


sub addYearNext {
	my ( $client, $url, $year, $remoteMeta, $tags ) = @_;
	my $add_string   = cstring($client, 'PLAY_NEXT');
	my $cmd = 'insert';
	addYear( $client, $url, $year, $remoteMeta, $tags, $add_string, $cmd ); 
}


sub addYear {
	my ( $client, $url, $year, $remoteMeta, $tags, $add_string, $cmd ) = @_;

	my $items = [];
	my $jive;
	

	my $actions = {
		go => {
			player => 0,
			cmd => [ 'playlistcontrol' ],
			params => {
				year => $year,
				cmd => $cmd,
			},
			nextWindow => 'parent',
		},
	};
	$actions->{play} = $actions->{go};
	$actions->{add}  = $actions->{go};

	$jive->{actions} = $actions;

	push @{$items}, {
		type => 'text',
		name => $add_string,
		jive => $jive, 
	};
	return $items;
}

sub _findDBCriteria {
	my $db = shift;
	
	my $findCriteria = '';
	foreach (keys %{$db->{findCriteria}}) {
		$findCriteria .= "&amp;$_=" . $db->{findCriteria}->{$_};
	}
	
	return $findCriteria;
}

sub cliQuery {
	$log->debug('cliQuery');
	my $request = shift;
	
	my $client         = $request->client;
	my $url            = $request->getParam('url');
	my $year           = $request->getParam('year');
	my $menuMode       = $request->getParam('menu') || 0;
	

	my $tags = {
		menuMode      => $menuMode,
	};

	unless ( $url || $year ) {
		$request->setStatusBadParams();
		return;
	}
	
	my $feed;
	
	# Default menu
	if ( $url ) {
		$feed = Slim::Menu::YearInfo->menu( $client, $url, undef, $tags );
	}
	else {
		$feed     = Slim::Menu::YearInfo->menu( $client, undef, $year, $tags );
	}
	
	Slim::Control::XMLBrowser::cliQuery( 'yearinfo', $feed, $request );
}

1;
