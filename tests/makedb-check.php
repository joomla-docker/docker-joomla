<?php
// Run with php -n so the stub driver exercises makedb.php without a database.
$source = $argv[1];
$scenario = $argv[2];
$fixture = $argv[3];
$events = array();

function check($condition, $message)
{
	if (!$condition)
	{
		throw new RuntimeException($message);
	}
}

if ($fixture === 'special')
{
	$host = "/tmp/socket dir\\with'quote";
	$user = "developer ' slash\\ user";
	$password = "secret '\\ password host=attacker";
	$database = "site ' \"; DROP DATABASE postgres; -- \\";
	$expectedConnection = "host='/tmp/socket dir\\\\with\\'quote' port=5544"
		. " user='developer \\' slash\\\\ user'"
		. " password='secret \\'\\\\ password host=attacker' dbname=postgres";
	$hostArgument = $host . ':5544';
}
elseif ($fixture === 'empty-password')
{
	$hostArgument = 'localhost';
	$user = 'joomla';
	$password = '';
	$database = 'joomla';
	$expectedConnection = "host='localhost' port=5432 user='joomla' password='' dbname=postgres";
}
else
{
	throw new RuntimeException('Unknown database test fixture.');
}

function pg_connect($connection)
{
	global $events, $expectedConnection;
	$events[] = 'connect';
	check($connection === $expectedConnection, 'Connection values were not correctly quoted for libpq.');
	return 'connection';
}

function pg_query_params($connection, $query, $parameters)
{
	global $events, $scenario, $database;
	$events[] = 'lookup';
	check($connection === 'connection', 'Lookup used the wrong connection.');
	check($query === 'SELECT 1 FROM pg_database WHERE datname = $1', 'Database lookup must use a parameter.');
	check($parameters === array($database), 'Database lookup changed the supplied database name.');
	return $scenario === 'lookup-failure' ? false : 'lookup-result';
}

function pg_num_rows($result)
{
	global $events, $scenario;
	$events[] = 'rows';
	check($result === 'lookup-result', 'A failed lookup was treated as a result.');
	return $scenario === 'existing' ? 1 : 0;
}

function pg_escape_identifier($connection, $value)
{
	global $events, $scenario, $database;
	$events[] = 'escape';
	check($connection === 'connection', 'Identifier escaping used the wrong connection.');
	check($value === $database, 'Identifier escaping changed the supplied database name.');
	// A distinct return value verifies the caller uses the driver's result.
	return $scenario === 'escape-failure' ? false : '"escaped-database-identifier"';
}

function pg_query($connection, $query)
{
	global $events, $scenario;
	$events[] = 'create';
	check($connection === 'connection', 'Database creation used the wrong connection.');
	check($query === 'CREATE DATABASE "escaped-database-identifier"', 'Database creation did not use the escaped identifier.');
	return $scenario !== 'create-failure';
}

function pg_close($connection)
{
	global $events;
	$events[] = 'close';
	check($connection === 'connection', 'The wrong database connection was closed.');
	return true;
}

register_shutdown_function(static function () use ($scenario) {
	global $events;
	$expected = array('connect', 'lookup');
	if ($scenario !== 'lookup-failure')
	{
		$expected[] = 'rows';
		if ($scenario !== 'existing')
		{
			$expected[] = 'escape';
			if ($scenario !== 'escape-failure')
			{
				$expected[] = 'create';
			}
		}
	}
	$expected[] = 'close';
	check($events === $expected, 'Unexpected PostgreSQL operations or missing connection cleanup.');
});

$argv = array($source, $hostArgument, $user, $password, $database, 'pgsql');
require $source;
