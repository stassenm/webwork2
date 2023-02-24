################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2022 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package WeBWorK::Utils::ProblemProcessing;
use Mojo::Base 'Exporter', -signatures;

=head1 NAME

WeBWorK::Utils::ProblemProcessing - contains subroutines for generating output
for the problem pages, especially those generated by Problem.pm.

=cut

use Mojo::JSON qw(encode_json);
use Email::Stuffer;
use Try::Tiny;

use WeBWorK::Debug;
use WeBWorK::Utils
	qw(writeLog writeCourseLogGivenTime encodeAnswers before after jitar_problem_adjusted_status jitar_id_to_seq);
use WeBWorK::Authen::LTIAdvanced::SubmitGrade;

use Caliper::Sensor;
use Caliper::Entity;

our @EXPORT_OK = qw(
	process_and_log_answer
	compute_reduced_score
	create_ans_str_from_responses
	jitar_send_warning_email
);

# Performs functions of processing and recording the answer given in the page.
# Returns the appropriate scoreRecordedMessage.
# Note that $c must be a WeBWorK::ContentGenerator object whose associated route is parented by the set_list route.
# In addition $c must have the neccessary hash data values set for this method.
# Those are 'will', 'problem', 'pg', and 'set'.
sub process_and_log_answer ($c) {
	my $ce            = $c->ce;
	my $db            = $c->db;
	my $effectiveUser = $c->param('effectiveUser');
	my $authz         = $c->authz;

	my %will          = %{ $c->{will} };
	my $submitAnswers = $c->{submitAnswers};
	my $problem       = $c->{problem};
	my $pg            = $c->{pg};
	my $set           = $c->{set};
	my $courseID      = $c->stash('courseID');

	# logging student answers
	my $pureProblem = $db->getUserProblem($problem->user_id, $problem->set_id, $problem->problem_id);
	my $answer_log  = $ce->{courseFiles}{logs}{answer_log};

	my ($encoded_last_answer_string, $scores2, $isEssay2);
	my $scoreRecordedMessage = '';

	if (defined($answer_log) && defined($pureProblem) && $submitAnswers) {
		my $past_answers_string;
		($past_answers_string, $encoded_last_answer_string, $scores2, $isEssay2) =
			create_ans_str_from_responses($c, $pg);

		if (!$authz->hasPermissions($effectiveUser, 'dont_log_past_answers')) {
			# Use the time the submission processing began, but must convert the
			# floating point value from Time::HiRes to an integer for use below.
			# Truncate towards 0 intentionally, so the integer value set is never
			# larger than the original floating point value.
			my $timestamp = int($c->submitTime);

			# store in answer_log
			writeCourseLogGivenTime(
				$ce,
				'answer_log',
				$timestamp,
				join('',
					'|', $problem->user_id, '|',  $problem->set_id, '|',  $problem->problem_id,
					'|', $scores2,          "\t", $timestamp,       "\t", $past_answers_string,
				),
			);

			# add to PastAnswer db
			my $pastAnswer = $db->newPastAnswer();
			$pastAnswer->course_id($courseID);
			$pastAnswer->user_id($problem->user_id);
			$pastAnswer->set_id($problem->set_id);
			$pastAnswer->problem_id($problem->problem_id);
			$pastAnswer->timestamp($timestamp);
			$pastAnswer->scores($scores2);
			$pastAnswer->answer_string($past_answers_string);
			$pastAnswer->source_file($problem->source_file);
			$db->addPastAnswer($pastAnswer);
		}
	}

	# this stores previous answers to the problem to provide "sticky answers"
	if ($submitAnswers) {
		if (defined $pureProblem) {
			# store answers in DB for sticky answers
			my %answersToStore;

			# store last answer to database for use in "sticky" answers
			$problem->last_answer($encoded_last_answer_string);
			$pureProblem->last_answer($encoded_last_answer_string);
			$db->putUserProblem($pureProblem);

			# store state in DB if it makes sense
			if ($will{recordAnswers}) {
				my $score =
					compute_reduced_score($ce, $problem, $set, $pg->{state}{recorded_score}, $c->submitTime);
				$problem->status($score) if $score > $problem->status;

				$problem->sub_status($problem->status)
					if (!$c->ce->{pg}{ansEvalDefaults}{enableReducedScoring}
						|| !$set->enable_reduced_scoring
						|| before($set->reduced_scoring_date, $c->submitTime));

				$problem->attempted(1);
				$problem->num_correct($pg->{state}{num_of_correct_ans});
				$problem->num_incorrect($pg->{state}{num_of_incorrect_ans});

				$pureProblem->status($problem->status);
				$pureProblem->sub_status($problem->sub_status);
				$pureProblem->attempted(1);
				$pureProblem->num_correct($pg->{state}{num_of_correct_ans});
				$pureProblem->num_incorrect($pg->{state}{num_of_incorrect_ans});

				# Add flags for an essay question.  If its an essay question and we are submitting then there could be
				# potential changes, and it should be flagged as needing grading.  Also check for the appropriate flag
				# in the global problem and set it.

				if ($isEssay2 && $pureProblem->{flags} !~ /needs_grading/) {
					$pureProblem->{flags} =~ s/graded,//;
					$pureProblem->{flags} .= "needs_grading,";
				}

				my $globalProblem = $db->getGlobalProblem($problem->set_id, $problem->problem_id);
				if ($isEssay2 && $globalProblem->{flags} !~ /essay/) {
					$globalProblem->{flags} .= 'essay,';
					$db->putGlobalProblem($globalProblem);
				} elsif (!$isEssay2 && $globalProblem->{flags} =~ /essay/) {
					$globalProblem->{flags} =~ s/essay,//;
					$db->putGlobalProblem($globalProblem);
				}

				if ($db->putUserProblem($pureProblem)) {
					$scoreRecordedMessage = $c->maketext('Your score was recorded.');
				} else {
					$scoreRecordedMessage = $c->maketext('Your score was not recorded because there was a failure '
							. 'in storing the problem record to the database.');
				}
				# write to the transaction log, just to make sure
				writeLog($ce, 'transaction',
					$problem->problem_id . "\t"
						. $problem->set_id . "\t"
						. $problem->user_id . "\t"
						. $problem->source_file . "\t"
						. $problem->value . "\t"
						. $problem->max_attempts . "\t"
						. $problem->problem_seed . "\t"
						. $pureProblem->status . "\t"
						. $pureProblem->attempted . "\t"
						. $pureProblem->last_answer . "\t"
						. $pureProblem->num_correct . "\t"
						. $pureProblem->num_incorrect);

				if ($ce->{caliper}{enabled}
					&& defined($answer_log)
					&& !$authz->hasPermissions($effectiveUser, 'dont_log_past_answers'))
				{
					my $caliper_sensor = Caliper::Sensor->new($ce);
					my $startTime      = $c->param('startTime');
					my $endTime        = time();

					my $completed_question_event = {
						type    => 'AssessmentItemEvent',
						action  => 'Completed',
						profile => 'AssessmentProfile',
						object  => Caliper::Entity::problem_user(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg
						),
						generated => Caliper::Entity::answer(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->problem_id(),
							$problem->user_id(),
							$pg,
							$startTime,
							$endTime
						),
					};
					my $submitted_set_event = {
						type      => 'AssessmentEvent',
						action    => 'Submitted',
						profile   => 'AssessmentProfile',
						object    => Caliper::Entity::problem_set($ce, $db, $problem->set_id()),
						generated => Caliper::Entity::problem_set_attempt(
							$ce,
							$db,
							$problem->set_id(),
							0,    #version is 0 for non-gateway problems
							$problem->user_id(),
							$startTime,
							$endTime
						),
					};
					my $tool_use_event = {
						type    => 'ToolUseEvent',
						action  => 'Used',
						profile => 'ToolUseProfile',
						object  => Caliper::Entity::webwork_app(),
					};
					$caliper_sensor->sendEvents($c,
						[ $completed_question_event, $submitted_set_event, $tool_use_event ]);

					# reset start time
					$c->param('startTime', '');
				}

				#Try to update the student score on the LMS
				# if that option is enabled.
				my $LTIGradeMode = $ce->{LTIGradeMode} // '';
				if ($LTIGradeMode && $ce->{LTIGradeOnSubmit}) {
					my $grader = WeBWorK::Authen::LTIAdvanced::SubmitGrade->new($c);
					if ($LTIGradeMode eq 'course') {
						if ($grader->submit_course_grade($problem->user_id)) {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was successfully sent to the LMS.');
						} else {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was not successfully sent to the LMS.');
						}
					} elsif ($LTIGradeMode eq 'homework') {
						if ($grader->submit_set_grade($problem->user_id, $problem->set_id)) {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was successfully sent to the LMS.');
						} else {
							$scoreRecordedMessage .=
								$c->tag('br') . $c->maketext('Your score was not successfully sent to the LMS.');
						}
					}
				}
			} else {
				if (before($set->open_date, $c->submitTime) || after($set->due_date, $c->submitTime)) {
					$scoreRecordedMessage =
						$c->maketext('Your score was not recorded because this homework set is closed.');
				} else {
					$scoreRecordedMessage = $c->maketext('Your score was not recorded.');
				}
			}
		} else {
			$scoreRecordedMessage =
				$c->maketext('Your score was not recorded because this problem has not been assigned to you.');
		}
	}

	$c->{scoreRecordedMessage} = $scoreRecordedMessage;
	return $scoreRecordedMessage;
}

# Determines if a set is in the reduced scoring period, and if so returns the reduced score.
# Otherwise it returns the unadjusted score.
sub compute_reduced_score ($ce, $problem, $set, $score, $submitTime) {
	# If no adjustments need to be applied, return the full score.
	if (!$ce->{pg}{ansEvalDefaults}{enableReducedScoring}
		|| !$set->enable_reduced_scoring
		|| !$set->reduced_scoring_date
		|| $set->reduced_scoring_date == $set->due_date
		|| before($set->reduced_scoring_date, $submitTime)
		|| $score <= $problem->sub_status)
	{
		return $score;
	}

	# Return the reduced score.
	return $problem->sub_status + $ce->{pg}{ansEvalDefaults}{reducedScoringValue} * ($score - $problem->sub_status);
}

# create answer string from responses hash
# ($past_answers_string, $encoded_last_answer_string, $scores, $isEssay) = create_ans_str_from_responses($problem, $pg)
#
# input: $problem - a 'WeBWorK::ContentGenerator::Problem object that has $problem->{formFields} set to a hash
#                   containing the appropriate data.
#        $pg      - a 'WeBWorK::PG' object
# output:  (str, str, str, bool)
#
# The extra persistence objects do need to be included in problem->last_answer
# in order to keep those objects persistent -- as long as RECORD_FORM_ANSWER
# is used to preserve objects by piggy backing on the persistence mechanism for answers.
sub create_ans_str_from_responses ($problem, $pg) {
	my $scores2  = '';
	my $isEssay2 = 0;
	my %answers_to_store;
	my @past_answers_order;
	my @last_answer_order;

	my %pg_answers_hash = %{ $pg->{PG_ANSWERS_HASH} };
	foreach my $ans_id (@{ $pg->{flags}{ANSWER_ENTRY_ORDER} // [] }) {
		$scores2 .= ($pg_answers_hash{$ans_id}{rh_ans}{score} // 0) >= 1 ? "1" : "0";
		$isEssay2 = 1 if ($pg_answers_hash{$ans_id}{rh_ans}{type} // '') eq 'essay';
		foreach my $response_id (@{ $pg_answers_hash{$ans_id}{response_obj}{response_order} }) {
			$answers_to_store{$response_id} = $problem->{formFields}{$response_id};
			push @past_answers_order, $response_id;
			push @last_answer_order,  $response_id;
		}
	}
	# KEPT_EXTRA_ANSWERS needs to be stored in last_answer in order to preserve persistence items.
	# The persistence items do not need to be stored in past_answers_string.
	foreach my $entry_id (@{ $pg->{flags}{KEPT_EXTRA_ANSWERS} }) {
		next if exists($answers_to_store{$entry_id});
		$answers_to_store{$entry_id} = $problem->{formFields}{$entry_id};
		push @last_answer_order, $entry_id;
	}

	my $past_answers_string = join(
		"\t",
		map {
			ref($answers_to_store{$_}) eq 'ARRAY'
				? join('&#9070;', @{ $answers_to_store{$_} })
				: ($answers_to_store{$_} // '')
		} @past_answers_order
	);

	my $encoded_last_answer_string = encodeAnswers(%answers_to_store, @last_answer_order);
	# past_answers_string is stored in past_answer table.
	# encoded_last_answer_string is used in `last_answer` entry of the problem_user table.
	return ($past_answers_string, $encoded_last_answer_string, $scores2, $isEssay2);
}

# If you provide this subroutine with a userProblem it will notify the instructors of the course that the student has
# finished the problem, and its children, and did not get 100%.
# Note that $c must be a WeBWorK::ContentGenerator object whose associated route is parented by the set_list route.
sub jitar_send_warning_email ($c, $userProblem) {
	my $ce        = $c->ce;
	my $db        = $c->db;
	my $authz     = $c->authz;
	my $courseID  = $c->stash('courseID');
	my $userID    = $userProblem->user_id;
	my $setID     = $userProblem->set_id;
	my $problemID = $userProblem->problem_id;

	my $status = jitar_problem_adjusted_status($userProblem, $c->db);
	$status = eval { sprintf('%.0f%%', $status * 100) };    # round to whole number

	my $user = $db->getUser($userID);

	debug("Couldn't get user $userID from database") unless $user;

	my $emailableURL =
		$c->systemLink($c->url_for, params => { effectiveUser => $userID }, use_abs_url => 1, authen => 0);

	my @recipients = $c->fetchEmailRecipients('score_sets', $user);
	# send to all users with permission to score_sets and an email address

	my $sender;
	if ($user->email_address) {
		$sender = $user->rfc822_mailbox;
	} elsif ($user->full_name) {
		$sender = $user->full_name;
	} else {
		$sender = $userID;
	}

	$problemID = join('.', jitar_id_to_seq($problemID));

	my %subject_map = (
		'c' => $courseID,
		'u' => $userID,
		's' => $setID,
		'p' => $problemID,
		'x' => $user->section,
		'r' => $user->recitation,
		'%' => '%',
	);
	my $chars   = join('', keys %subject_map);
	my $subject = $ce->{mail}{feedbackSubjectFormat}
		|| 'WeBWorK question from %c: %u set %s/prob %p';    # default if not entered
	$subject =~ s/%([$chars])/defined $subject_map{$1} ? $subject_map{$1} : ""/eg;

	my $full_name     = $user->full_name;
	my $email_address = $user->email_address;
	my $student_id    = $user->student_id;
	my $section       = $user->section;
	my $recitation    = $user->recitation;
	my $comment       = $user->comment;

	# print message
	my $msg = qq/
This  message was automatically generated by WeBWorK.

User $full_name ($userID) has not sucessfully completed the review for problem $problemID in set $setID.
Their final adjusted score on the problem is $status.

Click this link to visit the problem: $emailableURL

User ID:    $userID
Name:       $full_name
Email:      $email_address
Student ID: $student_id
Section:    $section
Recitation: $recitation
Comment:    $comment
/;

	my $email = Email::Stuffer->to(join(',', @recipients))->from($sender)->subject($subject)->text_body($msg);

	# Extra headers
	$email->header('X-WeBWorK-Course: ', $courseID) if defined $courseID;
	if ($user) {
		$email->header('X-WeBWorK-User: ',       $user->user_id);
		$email->header('X-WeBWorK-Section: ',    $user->section);
		$email->header('X-WeBWorK-Recitation: ', $user->recitation);
	}
	$email->header('X-WeBWorK-Set: ',     $setID)     if defined $setID;
	$email->header('X-WeBWorK-Problem: ', $problemID) if defined $problemID;

	# $ce->{mail}{set_return_path} is the address used to report returned email if defined and non empty.  It is an
	# argument used in sendmail() (aka Email::Stuffer::send_or_die).  For arcane historical reasons sendmail actually
	# sets the field "MAIL FROM" and the smtp server then uses that to set "Return-Path".
	# references:
	#  https://stackoverflow.com/questions/1235534/what-is-the-behavior-difference-between-return-path-reply-to-and-from
	#  https://metacpan.org/pod/Email::Sender::Manual::QuickStart#envelope-information
	try {
		$email->send_or_die({
			# createEmailSenderTransportSMTP is defined in ContentGenerator
			transport => $c->createEmailSenderTransportSMTP(),
			$ce->{mail}{set_return_path} ? (from => $ce->{mail}{set_return_path}) : ()
		});
		debug('Successfully sent JITAR alert message');
	} catch {
		$c->log->error("Failed to send JITAR alert message: $_");
	};

	return '';
}

1;
