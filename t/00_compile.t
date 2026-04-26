use strict;
use warnings;
use Test::More;


use VoteAnalyze;
use VoteAnalyze::Web;
use VoteAnalyze::Web::Dispatcher;
use VoteAnalyze::Web::C::Root;
use VoteAnalyze::Web::C::Account;
use VoteAnalyze::Web::ViewFunctions;
use VoteAnalyze::Web::View;
use VoteAnalyze::Admin;
use VoteAnalyze::Admin::Dispatcher;
use VoteAnalyze::Admin::C::Root;
use VoteAnalyze::Admin::ViewFunctions;
use VoteAnalyze::Admin::View;


pass "All modules can load.";

done_testing;
