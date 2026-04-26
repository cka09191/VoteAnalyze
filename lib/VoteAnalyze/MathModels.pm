package VoteAnalyze::MathModels;
use strict;
use warnings;
use utf8;
use List::Util qw(min max sum);
use Carp       qw(croak);

our $VERSION = '0.01';

# ---------------------------------------------------------------------------
# Module-level constants (mirrors Python module constants)
# ---------------------------------------------------------------------------
use constant {
    _LARGE_DATA_THRESHOLD => 500,
    _CONSENSUS_THRESHOLD  => 0.70,
    _DIVISIVE_GAP         => 0.50,
    _GROUP_REP_THRESHOLD  => 0.80,
};

# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

sub new {
    my ( $class, %args ) = @_;
    return bless {
        min_vote_rate           => $args{min_vote_rate}           // 0.5,
        min_votes_per_statement => $args{min_votes_per_statement} // 5,
        pca_variance_threshold  => $args{pca_variance_threshold}  // 0.80,
        k_range                 => $args{k_range}                 // [ 2, 7 ],
        large_data_threshold    => $args{large_data_threshold}    // _LARGE_DATA_THRESHOLD,
        random_state            => $args{random_state}            // 42,
    }, $class;
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# build_vote_matrix(\@votes, \@participant_ids, \@statement_ids)
# Each vote: { participant_id => ..., statement_id => ..., value => +1/-1/0 }
# Returns a vote_matrix hashref.
sub build_vote_matrix {
    my ( $self, $votes, $participant_ids, $statement_ids ) = @_;

    my %p_idx = map { $participant_ids->[$_] => $_ } 0 .. $#$participant_ids;
    my %s_idx = map { $statement_ids->[$_]   => $_ } 0 .. $#$statement_ids;

    my $np = scalar @$participant_ids;
    my $ns = scalar @$statement_ids;

    my @matrix = map { [ (0.0) x $ns ] } 0 .. $np - 1;

    for my $vote (@$votes) {
        my $pid = $vote->{participant_id};
        my $sid = $vote->{statement_id};
        if ( exists $p_idx{$pid} && exists $s_idx{$sid} ) {
            $matrix[ $p_idx{$pid} ][ $s_idx{$sid} ] = $vote->{value} + 0.0;
        }
    }

    return {
        matrix          => \@matrix,
        participant_ids => [@$participant_ids],
        statement_ids   => [@$statement_ids],
    };
}

# preprocess($vote_matrix)
# Removes low-participation participants and low-coverage statements.
# Returns a cleaned vote_matrix hashref.
sub preprocess {
    my ( $self, $vote_matrix ) = @_;

    my @matrix = map { [@$_] } @{ $vote_matrix->{matrix} };
    my @pids   = @{ $vote_matrix->{participant_ids} };
    my @sids   = @{ $vote_matrix->{statement_ids} };
    my $ns     = scalar @sids;

    # Filter participants by vote-completion rate
    my ( @kept_rows, @kept_pids );
    for my $i ( 0 .. $#matrix ) {
        my $nonzero = grep { $_ != 0 } @{ $matrix[$i] };
        if ( $nonzero / ( $ns || 1 ) >= $self->{min_vote_rate} ) {
            push @kept_rows, $matrix[$i];
            push @kept_pids, $pids[$i];
        }
    }
    @matrix = @kept_rows;
    @pids   = @kept_pids;
    my $np  = scalar @matrix;

    return {
        matrix          => \@matrix,
        participant_ids => \@pids,
        statement_ids   => \@sids,
    } unless $np;

    # Filter statements by minimum vote count
    my ( @kept_cols, @kept_sids );
    for my $j ( 0 .. $ns - 1 ) {
        my $count = grep { $matrix[$_][$j] != 0 } 0 .. $np - 1;
        if ( $count >= $self->{min_votes_per_statement} ) {
            push @kept_cols, $j;
            push @kept_sids, $sids[$j];
        }
    }
    if ( @kept_cols < $ns ) {
        @matrix = map { my $r = $_; [ map { $r->[$_] } @kept_cols ] } @matrix;
    }
    @sids = @kept_sids;

    return {
        matrix          => \@matrix,
        participant_ids => \@pids,
        statement_ids   => \@sids,
    };
}

# run_pca($vote_matrix)
# PCA via covariance-matrix eigendecomposition (power iteration / deflation).
# Returns a pca_result hashref.
sub run_pca {
    my ( $self, $vote_matrix ) = @_;

    my $M  = $vote_matrix->{matrix};
    my $np = scalar @$M;
    my $ns = scalar @{ $M->[0] };

    croak 'run_pca: empty matrix' unless $np >= 1 && $ns >= 1;

    my $max_components = min( $np, $ns );

    # Centre the data by subtracting column means
    my @col_means;
    for my $j ( 0 .. $ns - 1 ) {
        my $s = 0;
        $s += $M->[$_][$j] for 0 .. $np - 1;
        $col_means[$j] = $s / $np;
    }
    my @X = map {
        my $i = $_;
        [ map { $M->[$i][$_] - $col_means[$_] } 0 .. $ns - 1 ]
    } 0 .. $np - 1;

    # Covariance matrix: C = X^T * X / (n - 1)
    my $denom = $np > 1 ? $np - 1 : 1;
    my $C     = _mat_mul( _mat_transpose( \@X ), \@X );
    for my $i ( 0 .. $#$C ) {
        $C->[$i][$_] /= $denom for 0 .. $#{ $C->[$i] };
    }

    # Eigendecomposition via power iteration + deflation
    my ( $eigenvalues, $eigenvectors ) =
        _power_iteration_eigen( $C, $max_components, $self->{random_state} );

    # Sort descending by eigenvalue
    my @order       = sort { $eigenvalues->[$b] <=> $eigenvalues->[$a] } 0 .. $#$eigenvalues;
    my @sorted_vals = map  { $eigenvalues->[$_] }  @order;
    my @sorted_vecs = map  { $eigenvectors->[$_] } @order;

    # Explained variance ratio (use absolute values; negative eigenvalues are
    # numerical noise in near-singular covariance matrices)
    my $total_var = 0;
    $total_var += abs($_) for @sorted_vals;
    $total_var ||= 1;
    my @exp_var = map { abs($_) / $total_var } @sorted_vals;

    # Select minimum n_components covering >= pca_variance_threshold
    my $cumvar       = 0;
    my $n_components = $max_components;
    for my $i ( 0 .. $#exp_var ) {
        $cumvar += $exp_var[$i];
        if ( $cumvar >= $self->{pca_variance_threshold} ) {
            $n_components = $i + 1;
            last;
        }
    }
    $n_components = 2             if $n_components < 2;
    $n_components = $max_components if $n_components > $max_components;

    # 2-D projection for visualisation
    my @vecs_2d   = @sorted_vecs[ 0 .. 1 ];
    my $coords_2d = _project( \@X, \@vecs_2d );

    # n-D projection for clustering
    my ( $coords_nd, $components_nd, $exp_var_nd );
    if ( $n_components == 2 ) {
        $coords_nd    = $coords_2d;
        $components_nd = \@vecs_2d;
        $exp_var_nd    = [ @exp_var[ 0 .. 1 ] ];
    }
    else {
        my @vecs_nd    = @sorted_vecs[ 0 .. $n_components - 1 ];
        $coords_nd     = _project( \@X, \@vecs_nd );
        $components_nd = \@vecs_nd;
        $exp_var_nd    = [ @exp_var[ 0 .. $n_components - 1 ] ];
    }

    return {
        coords_2d                => $coords_2d,
        coords_nd                => $coords_nd,
        explained_variance_ratio => $exp_var_nd,
        components               => $components_nd,
        n_components             => $n_components,
    };
}

# run_kmeans($pca_result [, $k_override])
# Returns ($labels_arrayref, $optimal_k, $silhouette).
sub run_kmeans {
    my ( $self, $pca_result, $k_override ) = @_;

    my $coords = $pca_result->{coords_nd};
    my $np     = scalar @$coords;
    my $n_init = $np > $self->{large_data_threshold} ? 3 : 10;

    if ( defined $k_override ) {
        my $labels     = _kmeans( $coords, $k_override, $n_init, $self->{random_state} );
        my $silhouette = _silhouette_score( $coords, $labels );
        return ( $labels, $k_override, $silhouette );
    }

    my ( $min_k, $max_k ) = @{ $self->{k_range} };
    $max_k = $np - 1 if $max_k > $np - 1;
    $min_k = 2       if $min_k < 2;

    my ( $best_labels, $best_k, $best_score ) = ( undef, $min_k, -1.0 );

    for my $k ( $min_k .. $max_k ) {
        my $labels = _kmeans( $coords, $k, $n_init, $self->{random_state} );
        my $score  = _silhouette_score( $coords, $labels );
        if ( $score > $best_score ) {
            $best_score  = $score;
            $best_k      = $k;
            $best_labels = $labels;
        }
    }

    unless ( defined $best_labels ) {
        $best_labels = _kmeans( $coords, $min_k, $n_init, $self->{random_state} );
        $best_score  = _silhouette_score( $coords, $best_labels );
        $best_k      = $min_k;
    }

    return ( $best_labels, $best_k, $best_score );
}

# classify_statements($vote_matrix, $cluster_labels, $k)
# Returns arrayref of classification hashrefs.
sub classify_statements {
    my ( $self, $vote_matrix, $cluster_labels, $k ) = @_;

    my $M    = $vote_matrix->{matrix};
    my @sids = @{ $vote_matrix->{statement_ids} };
    my $np   = scalar @$M;
    my $ns   = scalar @{ $M->[0] };

    # Agree-rate per cluster per statement (+1 counts as agree)
    my @cluster_agree_rates = map { [ (0.0) x $ns ] } 0 .. $k - 1;
    for my $c ( 0 .. $k - 1 ) {
        my @members = grep { $cluster_labels->[$_] == $c } 0 .. $np - 1;
        next unless @members;
        for my $j ( 0 .. $ns - 1 ) {
            my $agree = grep { $M->[$_][$j] == 1 } @members;
            $cluster_agree_rates[$c][$j] = $agree / scalar @members;
        }
    }

    my @classifications;
    for my $j ( 0 .. $ns - 1 ) {
        my @rates = map { $cluster_agree_rates[$_][$j] } 0 .. $k - 1;

        my $is_consensus = !( grep { $_ < _CONSENSUS_THRESHOLD } @rates );

        my $min_r = $rates[0];
        my $max_r = $rates[0];
        for my $r (@rates) {
            $min_r = $r if $r < $min_r;
            $max_r = $r if $r > $max_r;
        }
        my $is_divisive = ( $max_r - $min_r ) >= _DIVISIVE_GAP;

        my @above = grep { $rates[$_] >= _GROUP_REP_THRESHOLD } 0 .. $k - 1;
        my $group_rep_for = @above == 1 ? $above[0] : undef;

        push @classifications, {
            statement_id             => $sids[$j],
            statement_index          => $j,
            is_consensus             => $is_consensus  ? 1 : 0,
            is_divisive              => $is_divisive   ? 1 : 0,
            group_representative_for => $group_rep_for,
        };
    }

    return \@classifications;
}

# run(\@votes, \@participant_ids, \@statement_ids [, $k_override])
# Executes the full analysis pipeline.
# Returns an analysis_result hashref.
sub run {
    my ( $self, $votes, $participant_ids, $statement_ids, $k_override ) = @_;

    my $raw     = $self->build_vote_matrix( $votes, $participant_ids, $statement_ids );
    my $cleaned = $self->preprocess($raw);

    my $pca_result = $self->run_pca($cleaned);
    my ( $cluster_labels, $optimal_k, $silhouette ) =
        $self->run_kmeans( $pca_result, $k_override );

    my $clusters        = $self->_build_cluster_infos( $cleaned, $cluster_labels, $optimal_k );
    my $classifications = $self->classify_statements( $cleaned, $cluster_labels, $optimal_k );

    return {
        vote_matrix               => $cleaned,
        pca                       => $pca_result,
        cluster_labels            => $cluster_labels,
        optimal_k                 => $optimal_k,
        silhouette                => $silhouette,
        clusters                  => $clusters,
        statement_classifications => $classifications,
    };
}

# ---------------------------------------------------------------------------
# Private: cluster info builder
# ---------------------------------------------------------------------------

sub _build_cluster_infos {
    my ( $self, $vote_matrix, $cluster_labels, $k ) = @_;

    my $M  = $vote_matrix->{matrix};
    my $np = scalar @$M;
    my $ns = scalar @{ $M->[0] };

    my @infos;
    for my $c ( 0 .. $k - 1 ) {
        my @members  = grep { $cluster_labels->[$_] == $c } 0 .. $np - 1;
        my $size     = scalar @members;
        my $fraction = $size / ( $np || 1 );

        my @agree_rates = (0.0) x $ns;
        if ($size) {
            for my $j ( 0 .. $ns - 1 ) {
                my $agree = grep { $M->[$_][$j] == 1 } @members;
                $agree_rates[$j] = $agree / $size;
            }
        }

        push @infos, {
            label       => $c,
            size        => $size,
            fraction    => $fraction,
            agree_rates => \@agree_rates,
        };
    }
    return \@infos;
}

# ---------------------------------------------------------------------------
# Private: linear algebra helpers
# All matrix functions accept and return arrayrefs (arrayref of arrayrefs).
# Vector functions accept arrayrefs and return scalars or flat lists.
# ---------------------------------------------------------------------------

# Matrix multiplication: C = A * B
sub _mat_mul {
    my ( $A, $B ) = @_;
    my $rows_A = scalar @$A;
    my $cols_A = scalar @{ $A->[0] };
    my $cols_B = scalar @{ $B->[0] };
    my @C;
    for my $i ( 0 .. $rows_A - 1 ) {
        my @row;
        for my $j ( 0 .. $cols_B - 1 ) {
            my $s = 0;
            $s += $A->[$i][$_] * $B->[$_][$j] for 0 .. $cols_A - 1;
            push @row, $s;
        }
        push @C, \@row;
    }
    return \@C;
}

# Matrix transpose
sub _mat_transpose {
    my ($A) = @_;
    my $rows = scalar @$A;
    my $cols = scalar @{ $A->[0] };
    my @T;
    for my $j ( 0 .. $cols - 1 ) {
        push @T, [ map { $A->[$_][$j] } 0 .. $rows - 1 ];
    }
    return \@T;
}

# Matrix-vector multiplication: result = A * v
sub _mat_vec_mul {
    my ( $A, $v ) = @_;
    my $rows = scalar @$A;
    my @result;
    for my $i ( 0 .. $rows - 1 ) {
        my $s = 0;
        $s += $A->[$i][$_] * $v->[$_] for 0 .. $#$v;
        push @result, $s;
    }
    return \@result;
}

# Dot product of two vectors (arrayrefs)
sub _vec_dot {
    my ( $a, $b ) = @_;
    my $s = 0;
    $s += $a->[$_] * $b->[$_] for 0 .. $#$a;
    return $s;
}

# Euclidean norm of a vector (arrayref)
sub _vec_norm {
    my ($v) = @_;
    my $s = 0;
    $s += $_ * $_ for @$v;
    return sqrt($s);
}

# Squared Euclidean distance between two vectors (arrayrefs)
sub _sq_dist {
    my ( $a, $b ) = @_;
    my $s = 0;
    $s += ( $a->[$_] - $b->[$_] ) ** 2 for 0 .. $#$a;
    return $s;
}

# Project data matrix X onto a set of eigenvectors.
# $X: arrayref of row-vectors (arrayrefs)
# $vecs: arrayref of eigenvectors (arrayrefs) — each is a column direction
# Returns arrayref of projected rows.
sub _project {
    my ( $X, $vecs ) = @_;
    my $k = scalar @$vecs;
    my @projected;
    for my $row (@$X) {
        push @projected, [ map { _vec_dot( $row, $vecs->[$_] ) } 0 .. $k - 1 ];
    }
    return \@projected;
}

# ---------------------------------------------------------------------------
# Private: eigendecomposition via power iteration + deflation
#
# Computes the top $k (eigenvalue, eigenvector) pairs of a symmetric matrix.
# Uses a deterministic starting vector seeded by $seed to ensure
# reproducibility (analogous to sklearn's random_state).
# ---------------------------------------------------------------------------

sub _power_iteration_eigen {
    my ( $A, $k, $seed ) = @_;

    my $n = scalar @$A;
    $k = $n if $k > $n;

    # Working copy of A (we deflate in-place)
    my @mat = map { [@$_] } @$A;

    my ( @eigenvalues, @eigenvectors );

    for my $iter ( 0 .. $k - 1 ) {
        # Deterministic starting vector — varies per iteration
        my @b;
        for my $i ( 0 .. $n - 1 ) {
            push @b, sin( $i * 2.3999 + $seed * 0.1 + $iter * 1.7321 );
        }
        my $norm = _vec_norm( \@b );
        if ( $norm < 1e-14 ) {
            @b = map { 1.0 / sqrt($n) } 0 .. $n - 1;
        }
        else {
            @b = map { $_ / $norm } @b;
        }

        # Power iteration (max 1000 steps)
        for my $step ( 0 .. 999 ) {
            my $nb    = _mat_vec_mul( \@mat, \@b );
            my $nnorm = _vec_norm($nb);
            last if $nnorm < 1e-14;

            my @nb_norm = map { $_ / $nnorm } @$nb;

            # Check convergence: squared change in direction
            my $diff = 0;
            $diff += ( $nb_norm[$_] - $b[$_] ) ** 2 for 0 .. $n - 1;
            @b = @nb_norm;
            last if $diff < 1e-20;
        }

        # Rayleigh quotient: lambda = b^T * mat * b
        my $Ab     = _mat_vec_mul( \@mat, \@b );
        my $lambda = _vec_dot( \@b, $Ab );

        push @eigenvalues,  $lambda;
        push @eigenvectors, [@b];

        # Deflate: mat = mat - lambda * b * b^T
        for my $i ( 0 .. $n - 1 ) {
            for my $j ( 0 .. $n - 1 ) {
                $mat[$i][$j] -= $lambda * $b[$i] * $b[$j];
            }
        }
    }

    return ( \@eigenvalues, \@eigenvectors );
}

# ---------------------------------------------------------------------------
# Private: k-means clustering
# ---------------------------------------------------------------------------

# k-means++ style initialisation (deterministic via seed arithmetic)
sub _kmeans_init {
    my ( $data, $k, $seed ) = @_;
    my $n = scalar @$data;

    my @centroids;
    push @centroids, [ @{ $data->[ $seed % $n ] } ];

    for my $ci ( 1 .. $k - 1 ) {
        # Distance-squared to nearest existing centroid for each point
        my ( @dists, $total );
        for my $i ( 0 .. $n - 1 ) {
            my $min_d = 9e18;
            for my $c (@centroids) {
                my $d = _sq_dist( $data->[$i], $c );
                $min_d = $d if $d < $min_d;
            }
            push @dists, $min_d;
            $total += $min_d;
        }

        # Weighted pick — deterministic via seed
        my $threshold = $total > 0
            ? $total * ( ( $seed * 1009 + $ci * 997 ) % 9973 ) / 9973
            : 0;
        my $cumsum = 0;
        my $chosen = $n - 1;
        for my $i ( 0 .. $n - 1 ) {
            $cumsum += $dists[$i];
            if ( $cumsum >= $threshold ) {
                $chosen = $i;
                last;
            }
        }
        push @centroids, [ @{ $data->[$chosen] } ];
    }

    return @centroids;
}

# Run k-means with $n_init restarts; returns arrayref of cluster labels.
sub _kmeans {
    my ( $data, $k, $n_init, $seed ) = @_;

    my $n = scalar @$data;
    my $d = scalar @{ $data->[0] };

    my ( $best_labels, $best_inertia ) = ( undef, 9e18 );

    for my $init ( 0 .. $n_init - 1 ) {
        my @centroids = _kmeans_init( $data, $k, $seed + $init * 37 );
        my @labels    = (0) x $n;

        for my $step ( 0 .. 299 ) {
            # Assignment step
            my @new_labels;
            for my $i ( 0 .. $n - 1 ) {
                my ( $best_c, $best_d ) = ( 0, 9e18 );
                for my $c ( 0 .. $k - 1 ) {
                    my $dist = _sq_dist( $data->[$i], $centroids[$c] );
                    if ( $dist < $best_d ) {
                        $best_d = $dist;
                        $best_c = $c;
                    }
                }
                push @new_labels, $best_c;
            }

            # Convergence check
            my $changed = 0;
            for my $ci ( 0 .. $n - 1 ) {
                $changed++ if $new_labels[$ci] != $labels[$ci];
            }
            @labels = @new_labels;
            last unless $changed;

            # Update centroids
            for my $c ( 0 .. $k - 1 ) {
                my @members = grep { $labels[$_] == $c } 0 .. $n - 1;
                next unless @members;
                for my $dim ( 0 .. $d - 1 ) {
                    my $s = 0;
                    $s += $data->[$_][$dim] for @members;
                    $centroids[$c][$dim] = $s / scalar @members;
                }
            }
        }

        # Compute inertia (sum of squared distances to assigned centroid)
        my $inertia = 0;
        $inertia += _sq_dist( $data->[$_], $centroids[ $labels[$_] ] )
            for 0 .. $n - 1;

        if ( $inertia < $best_inertia ) {
            $best_inertia = $inertia;
            $best_labels  = [@labels];
        }
    }

    return $best_labels;
}

# Mean silhouette score: mean_i (b_i - a_i) / max(a_i, b_i)
# a_i = mean intra-cluster distance, b_i = mean nearest-cluster distance
sub _silhouette_score {
    my ( $data, $labels ) = @_;

    my $n = scalar @$data;
    my %unique;
    $unique{$_}++ for @$labels;
    return 0.0 if keys %unique <= 1;

    my $total = 0;
    for my $i ( 0 .. $n - 1 ) {
        my $ci = $labels->[$i];

        # Mean intra-cluster distance (a)
        my @same = grep { $_ != $i && $labels->[$_] == $ci } 0 .. $n - 1;
        my $a;
        if (@same) {
            my $s = 0;
            $s += sqrt( _sq_dist( $data->[$i], $data->[$_] ) ) for @same;
            $a = $s / scalar @same;
        }
        else {
            $a = 0.0;
        }

        # Mean nearest-cluster distance (b)
        my $b;
        for my $cj ( keys %unique ) {
            next if $cj == $ci;
            my @others = grep { $labels->[$_] == $cj } 0 .. $n - 1;
            next unless @others;
            my $s = 0;
            $s += sqrt( _sq_dist( $data->[$i], $data->[$_] ) ) for @others;
            my $mean = $s / scalar @others;
            $b = $mean if !defined $b || $mean < $b;
        }
        $b //= 0.0;

        my $max_ab = $a > $b ? $a : $b;
        $total += $max_ab > 0 ? ( $b - $a ) / $max_ab : 0.0;
    }

    return $total / $n;
}

1;

__END__

=head1 NAME

VoteAnalyze::MathModels - Opinion-clustering pipeline (PCA + k-means)

=head1 SYNOPSIS

    use VoteAnalyze::MathModels;

    my $analyzer = VoteAnalyze::MathModels->new(
        min_vote_rate           => 0.5,
        min_votes_per_statement => 5,
        pca_variance_threshold  => 0.80,
        k_range                 => [2, 7],
        random_state            => 42,
    );

    my $result = $analyzer->run(
        \@votes,            # [{participant_id=>'p1', statement_id=>'s1', value=>1}, ...]
        \@participant_ids,
        \@statement_ids,
    );

    # $result->{optimal_k}                  -- chosen number of clusters
    # $result->{silhouette}                 -- silhouette score
    # $result->{clusters}                   -- arrayref of cluster info hashrefs
    # $result->{statement_classifications}  -- arrayref of classification hashrefs

=head1 DESCRIPTION

Pure-Perl port of C<math_models.py>.  Implements the four-step Grand Maison
opinion-clustering pipeline described in ARCHITECTURE.md §2.4:

=over 4

=item 1. Vote-matrix construction

=item 2. PCA dimensionality reduction (power-iteration eigendecomposition)

=item 3. k-means clustering with silhouette-based optimal-k selection

=item 4. Statement classification (consensus / divisive / group-representative)

=back

No external numeric libraries are required.

=head1 DATA STRUCTURES

All data objects are plain hashrefs (Perl equivalent of the Python dataclasses).

=head2 vote_matrix

    {
        matrix          => $aoa,   # arrayref of arrayrefs — float values
        participant_ids => $aref,  # ordered participant ID strings
        statement_ids   => $aref,  # ordered statement ID strings
    }

=head2 pca_result

    {
        coords_2d                => $aoa,   # (n_participants x 2) — visualisation
        coords_nd                => $aoa,   # (n_participants x n_components) — clustering
        explained_variance_ratio => $aref,  # per-component explained variance
        components               => $aoa,   # eigenvectors (n_components x n_statements)
        n_components             => $int,
    }

=head2 cluster_info

    {
        label       => $int,
        size        => $int,
        fraction    => $float,
        agree_rates => $aref,   # per-statement agree rate within cluster
    }

=head2 statement_classification

    {
        statement_id             => $str,
        statement_index          => $int,
        is_consensus             => 0|1,
        is_divisive              => 0|1,
        group_representative_for => $int | undef,
    }

=head2 analysis_result

    {
        vote_matrix               => $vote_matrix_href,
        pca                       => $pca_result_href,
        cluster_labels            => $aref,
        optimal_k                 => $int,
        silhouette                => $float,
        clusters                  => $aref,   # arrayref of cluster_info hashrefs
        statement_classifications => $aref,   # arrayref of classification hashrefs
    }

=head1 METHODS

=head2 new(%args)

Constructor.  All arguments are optional.

    min_vote_rate           => 0.5    # exclude participants below this completion rate
    min_votes_per_statement => 5      # exclude statements with fewer non-zero votes
    pca_variance_threshold  => 0.80   # target cumulative explained variance for n_components
    k_range                 => [2,7]  # inclusive [min_k, max_k] for silhouette search
    large_data_threshold    => 500    # above this, use 3 restarts instead of 10
    random_state            => 42     # seed for reproducibility

=head2 build_vote_matrix(\@votes, \@participant_ids, \@statement_ids)

Build a raw vote_matrix hashref from a list of vote record hashrefs.

=head2 preprocess($vote_matrix)

Filter low-participation participants and low-coverage statements.
Returns a cleaned vote_matrix hashref.

=head2 run_pca($vote_matrix)

Run PCA via covariance-matrix eigendecomposition.
Returns a pca_result hashref.

=head2 run_kmeans($pca_result [, $k_override])

Cluster participants via k-means on PCA-reduced coordinates.
Auto-selects optimal k by silhouette score unless C<$k_override> is given.
Returns C<($labels_aref, $optimal_k, $silhouette)>.

=head2 classify_statements($vote_matrix, $cluster_labels, $k)

Classify each statement as consensus, divisive, and/or group-representative.
Returns an arrayref of statement_classification hashrefs.

=head2 run(\@votes, \@participant_ids, \@statement_ids [, $k_override])

Execute the full pipeline and return an analysis_result hashref.

=head1 CLASSIFICATION THRESHOLDS

    Consensus      all clusters show >= 70 % agree rate
    Divisive       max inter-cluster agree-rate gap >= 50 percentage points
    Group-rep      exactly one cluster shows >= 80 % agree rate

=head1 AUTHOR

VoteAnalyze authors.

=cut
