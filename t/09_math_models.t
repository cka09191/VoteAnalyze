use strict;
use warnings;
use Test::More;
use VoteAnalyze::MathModels;

# Build a simple two-group vote dataset.
#
# Group A (p1..p5) strongly agrees with s1, s2 and disagrees with s3, s4.
# Group B (p6..p10) disagrees with s1, s2 and strongly agrees with s3, s4.
# s5 gets +1 from everyone (consensus).
sub _two_group_votes {
    my @pids = map { "p$_" } 1 .. 10;
    my @sids = map { "s$_" } 1 .. 5;

    my @votes;
    for my $i ( 0 .. 4 ) {    # Group A: p1-p5
        push @votes,
            { participant_id => $pids[$i], statement_id => 's1', value =>  1 },
            { participant_id => $pids[$i], statement_id => 's2', value =>  1 },
            { participant_id => $pids[$i], statement_id => 's3', value => -1 },
            { participant_id => $pids[$i], statement_id => 's4', value => -1 },
            { participant_id => $pids[$i], statement_id => 's5', value =>  1 };
    }
    for my $i ( 5 .. 9 ) {    # Group B: p6-p10
        push @votes,
            { participant_id => $pids[$i], statement_id => 's1', value => -1 },
            { participant_id => $pids[$i], statement_id => 's2', value => -1 },
            { participant_id => $pids[$i], statement_id => 's3', value =>  1 },
            { participant_id => $pids[$i], statement_id => 's4', value =>  1 },
            { participant_id => $pids[$i], statement_id => 's5', value =>  1 };
    }

    return ( \@votes, \@pids, \@sids );
}

subtest 'constructor' => sub {
    my $m = VoteAnalyze::MathModels->new;
    isa_ok( $m, 'VoteAnalyze::MathModels', 'new returns object' );

    is( $m->{min_vote_rate},           0.5,      'default min_vote_rate' );
    is( $m->{min_votes_per_statement}, 5,        'default min_votes_per_statement' );
    is( $m->{pca_variance_threshold},  0.80,     'default pca_variance_threshold' );
    is_deeply( $m->{k_range},          [ 2, 7 ], 'default k_range' );
    is( $m->{random_state},            42,       'default random_state' );
};

subtest 'constructor with custom parameters' => sub {
    my $m = VoteAnalyze::MathModels->new(
        min_vote_rate           => 0.3,
        min_votes_per_statement => 2,
        pca_variance_threshold  => 0.90,
        k_range                 => [ 3, 5 ],
        random_state            => 7,
    );
    is( $m->{min_vote_rate},           0.3,      'custom min_vote_rate' );
    is( $m->{min_votes_per_statement}, 2,        'custom min_votes_per_statement' );
    is( $m->{pca_variance_threshold},  0.90,     'custom pca_variance_threshold' );
    is_deeply( $m->{k_range},          [ 3, 5 ], 'custom k_range' );
    is( $m->{random_state},            7,        'custom random_state' );
};

subtest 'build_vote_matrix' => sub {
    my $m    = VoteAnalyze::MathModels->new;
    my @pids = qw(p1 p2);
    my @sids = qw(s1 s2 s3);
    my @votes = (
        { participant_id => 'p1', statement_id => 's1', value =>  1 },
        { participant_id => 'p1', statement_id => 's3', value => -1 },
        { participant_id => 'p2', statement_id => 's2', value =>  1 },
    );

    my $vm = $m->build_vote_matrix( \@votes, \@pids, \@sids );

    is_deeply( $vm->{participant_ids}, \@pids, 'participant_ids preserved' );
    is_deeply( $vm->{statement_ids},   \@sids, 'statement_ids preserved' );

    is( $vm->{matrix}[0][0],  1,  'p1-s1 = +1' );
    is( $vm->{matrix}[0][1],  0,  'p1-s2 = 0 (not voted)' );
    is( $vm->{matrix}[0][2], -1,  'p1-s3 = -1' );
    is( $vm->{matrix}[1][0],  0,  'p2-s1 = 0' );
    is( $vm->{matrix}[1][1],  1,  'p2-s2 = +1' );
    is( $vm->{matrix}[1][2],  0,  'p2-s3 = 0' );

    # Unknown participant/statement IDs are silently ignored
    my @extra_votes = (
        { participant_id => 'p99', statement_id => 's1',  value => 1 },
        { participant_id => 'p1',  statement_id => 's99', value => 1 },
    );
    my $vm2 = $m->build_vote_matrix( \@extra_votes, \@pids, \@sids );
    is( $vm2->{matrix}[0][0], 0, 'unknown ids are ignored' );
};

subtest 'preprocess' => sub {
    my $m = VoteAnalyze::MathModels->new( min_vote_rate => 0.5, min_votes_per_statement => 2 );

    # p1 voted on 2/3 statements (rate ~0.67 >= 0.5) — kept
    # p2 voted on 1/3 statements (rate ~0.33 < 0.5)  — removed
    my $vm = {
        matrix          => [ [ 1, 0, -1 ], [ 1, 0, 0 ] ],
        participant_ids => [qw(p1 p2)],
        statement_ids   => [qw(s1 s2 s3)],
    };

    my $clean = $m->preprocess($vm);

    is( scalar @{ $clean->{participant_ids} }, 1, 'low-participation participant removed' );
    is( $clean->{participant_ids}[0], 'p1', 'correct participant kept' );

    # s2 has 0 votes after p2 removed — removed (< 2)
    # s1 and s3 have 1 vote each, also < 2 — all statements removed
    is( scalar @{ $clean->{statement_ids} }, 0, 'statements with too few votes removed' );
};

subtest 'preprocess with all participants/statements meeting thresholds' => sub {
    # All participants meet vote rate; all statements meet minimum count
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m  = VoteAnalyze::MathModels->new( min_vote_rate => 0.5, min_votes_per_statement => 5 );
    my $vm = $m->build_vote_matrix( $votes, $pids, $sids );
    my $clean = $m->preprocess($vm);

    is( scalar @{ $clean->{participant_ids} }, 10, 'all participants kept' );
    is( scalar @{ $clean->{statement_ids} },   5,  'all statements kept' );
};

subtest 'run_pca' => sub {
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m  = VoteAnalyze::MathModels->new;
    my $vm = $m->build_vote_matrix( $votes, $pids, $sids );

    my $pca = $m->run_pca($vm);

    ok( defined $pca->{coords_2d},  'coords_2d present' );
    ok( defined $pca->{coords_nd},  'coords_nd present' );
    ok( defined $pca->{n_components}, 'n_components present' );
    ok( defined $pca->{explained_variance_ratio}, 'explained_variance_ratio present' );
    ok( defined $pca->{components}, 'components present' );

    is( scalar @{ $pca->{coords_2d} }, 10, 'coords_2d has one row per participant' );
    is( scalar @{ $pca->{coords_2d}[0] }, 2, 'coords_2d rows have 2 dimensions' );

    cmp_ok( $pca->{n_components}, '>=', 2, 'n_components >= 2' );

    my $sum_var = 0;
    $sum_var += $_ for @{ $pca->{explained_variance_ratio} };
    cmp_ok( $sum_var, '>', 0, 'explained variance > 0' );
    cmp_ok( $sum_var, '<=', 1.001, 'explained variance ratio <= 1 (within floating-point tolerance)' );
};

subtest 'run_pca empty matrix' => sub {
    my $m = VoteAnalyze::MathModels->new;
    eval { $m->run_pca( { matrix => [], participant_ids => [], statement_ids => [] } ) };
    like( $@, qr/run_pca.*empty matrix/i, 'run_pca croaks on empty matrix' );
};

subtest 'run_kmeans' => sub {
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m     = VoteAnalyze::MathModels->new( k_range => [ 2, 4 ] );
    my $vm    = $m->build_vote_matrix( $votes, $pids, $sids );
    my $pca   = $m->run_pca($vm);

    my ( $labels, $k, $score ) = $m->run_kmeans($pca);

    ok( defined $labels, 'labels returned' );
    is( scalar @$labels, 10, 'one label per participant' );
    cmp_ok( $k, '>=', 2, 'k >= 2' );
    cmp_ok( $k, '<=', 4, 'k <= 4' );
    cmp_ok( $score, '>=', -1.0, 'silhouette >= -1' );
    cmp_ok( $score, '<=',  1.0, 'silhouette <=  1' );

    # Each label must be in [0, k-1]
    for my $l (@$labels) {
        cmp_ok( $l, '>=', 0,     "label $l >= 0" );
        cmp_ok( $l, '<=', $k-1,  "label $l <= k-1" );
    }
};

subtest 'run_kmeans with k_override' => sub {
    # k_override bypasses the silhouette search
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m   = VoteAnalyze::MathModels->new;
    my $vm  = $m->build_vote_matrix( $votes, $pids, $sids );
    my $pca = $m->run_pca($vm);

    my ( $labels, $k, $score ) = $m->run_kmeans( $pca, 3 );
    is( $k, 3, 'k_override respected' );
    is( scalar @$labels, 10, 'labels produced with k_override' );
};

subtest 'classify_statements' => sub {
    my $m = VoteAnalyze::MathModels->new;

    # Two clusters of 5:
    #   cluster 0 (rows 0-4): all agree on s1(1), disagree on s2(-1), agree on s3(1)
    #   cluster 1 (rows 5-9): all agree on s1(1), agree  on s2(1),    disagree on s3(-1)
    #
    # s1 -> all clusters >= 0.70 agree  => consensus
    # s2 -> rates differ by 1.0 (0 vs 1) => divisive, also group-rep for cluster 1
    # s3 -> rates differ by 1.0 (1 vs 0) => divisive, also group-rep for cluster 0

    my @matrix = (
        map( { [ 1,  -1,  1 ] } 0..4 ),   # cluster 0: agree s1, disagree s2, agree s3
        map( { [ 1,   1, -1 ] } 5..9 ),   # cluster 1: agree s1, agree s2, disagree s3
    );
    my $vm = {
        matrix          => \@matrix,
        participant_ids => [ map { "p$_" } 1..10 ],
        statement_ids   => [qw(s1 s2 s3)],
    };

    my $labels = [ (0)x5, (1)x5 ];
    my $cls    = $m->classify_statements( $vm, $labels, 2 );

    is( scalar @$cls, 3, 'one classification per statement' );

    my %by_id = map { $_->{statement_id} => $_ } @$cls;

    ok( $by_id{s1}{is_consensus},   's1 is consensus' );
    ok( !$by_id{s1}{is_divisive},   's1 is not divisive' );

    ok( !$by_id{s2}{is_consensus},  's2 is not consensus' );
    ok( $by_id{s2}{is_divisive},    's2 is divisive' );
    is( $by_id{s2}{group_representative_for}, 1, 's2 is group-rep for cluster 1' );

    ok( !$by_id{s3}{is_consensus},  's3 is not consensus' );
    ok( $by_id{s3}{is_divisive},    's3 is divisive' );
    is( $by_id{s3}{group_representative_for}, 0, 's3 is group-rep for cluster 0' );

    # statement_index should match position in statement_ids
    is( $by_id{s1}{statement_index}, 0, 's1 statement_index = 0' );
    is( $by_id{s2}{statement_index}, 1, 's2 statement_index = 1' );
    is( $by_id{s3}{statement_index}, 2, 's3 statement_index = 2' );
};

subtest 'run full pipeline' => sub {
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m      = VoteAnalyze::MathModels->new( k_range => [ 2, 3 ] );
    my $result = $m->run( $votes, $pids, $sids );

    ok( defined $result->{vote_matrix},               'result has vote_matrix' );
    ok( defined $result->{pca},                       'result has pca' );
    ok( defined $result->{cluster_labels},            'result has cluster_labels' );
    ok( defined $result->{optimal_k},                 'result has optimal_k' );
    ok( defined $result->{silhouette},                'result has silhouette' );
    ok( defined $result->{clusters},                  'result has clusters' );
    ok( defined $result->{statement_classifications}, 'result has statement_classifications' );

    is( scalar @{ $result->{cluster_labels} }, 10, 'one label per participant' );
    cmp_ok( $result->{optimal_k}, '>=', 2, 'optimal_k >= 2' );

    my $cls = $result->{statement_classifications};
    is( scalar @$cls, 5, 'five statement classifications' );

    # s5 is agreed on by everyone: should be consensus
    my ($s5) = grep { $_->{statement_id} eq 's5' } @$cls;
    ok( defined $s5,              's5 classification present' );
    ok( $s5->{is_consensus},      's5 is consensus (all agree)' );

    # Each cluster info should have the expected keys
    for my $c ( @{ $result->{clusters} } ) {
        ok( defined $c->{label},       "cluster $c->{label} has label" );
        ok( defined $c->{size},        "cluster $c->{label} has size" );
        ok( defined $c->{fraction},    "cluster $c->{label} has fraction" );
        ok( defined $c->{agree_rates}, "cluster $c->{label} has agree_rates" );
    }

    # Cluster fractions must sum to 1
    my $sum_frac = 0;
    $sum_frac += $_->{fraction} for @{ $result->{clusters} };
    cmp_ok( abs( $sum_frac - 1.0 ), '<', 1e-9, 'cluster fractions sum to 1' );
};

subtest 'run with k_override' => sub {
    my ( $votes, $pids, $sids ) = _two_group_votes();
    my $m      = VoteAnalyze::MathModels->new;
    my $result = $m->run( $votes, $pids, $sids, 2 );
    is( $result->{optimal_k}, 2, 'run respects k_override' );
};

done_testing;
