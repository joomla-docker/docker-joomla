<?php

// Fetch the current 3.x version from the downloads site API
$ch = curl_init();

curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_URL, 'https://downloads.joomla.org/api/v1/latest/cms');

$result = curl_exec($ch);

curl_close($ch);

if ($result === false)
{
	echo 'Could not fetch version data, please check your connection.' . PHP_EOL;

	exit(1);
}

$data = json_decode($result, true);

foreach ($data['branches'] as $branch)
{
	if ($branch['branch'] === 'Joomla! 3')
	{
		$version = $branch['version'];
	}
}

if (!isset($version))
{
	echo 'Joomla! 3.x version data not included in API response.' . PHP_EOL;

	exit(1);
}

$urlVersion = str_replace('.', '-', $version);

$filename = "Joomla_$version-Stable-Full_Package.tar.bz2";

// Fetch the SHA1 signature for the file
$ch = curl_init();

curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_URL, "https://downloads.joomla.org/api/v1/signatures/cms/$urlVersion");

$result = curl_exec($ch);

curl_close($ch);

if ($result === false)
{
	echo 'Could not fetch signature data, please check your connection.' . PHP_EOL;

	exit(1);
}

$data = json_decode($result, true);

foreach ($data['files'] as $file)
{
	if ($file['filename'] === $filename)
	{
		$signature = $file['sha1'];
	}
}

if (!isset($signature))
{
	echo 'tar.bz2 file SHA1 signature not included in API response.' . PHP_EOL;

	exit(1);
}

$phpVersions = [];
$platforms   = ['apache', 'fpm', 'fpm-alpine'];

/** @var DirectoryIterator $dir */
foreach (new DirectoryIterator(__DIR__) as $dir)
{
	if (substr($dir->getFilename(), 0, 3) === 'php')
	{
		$phpVersions[] = $dir->getFilename();
	}
}

foreach ($phpVersions as $phpVersion)
{
	foreach ($platforms as $platform)
	{
		$dockerfile = __DIR__ . "/$phpVersion/$platform/Dockerfile";

		$fileContents = file_get_contents($dockerfile);
		$fileContents = preg_replace('#ENV JOOMLA_VERSION [^ ]*\n#', "ENV JOOMLA_VERSION $version\n", $fileContents);
		$fileContents = preg_replace('#ENV JOOMLA_SHA1 [^ ]*\n#', "ENV JOOMLA_SHA1 $signature\n\n", $fileContents);

		file_put_contents($dockerfile, $fileContents);

		// To make management easier, we use these files for all variants
		copy(__DIR__ . '/docker-entrypoint.sh', __DIR__ . "/$phpVersion/$platform/docker-entrypoint.sh");
		copy(__DIR__ . '/makedb.php', __DIR__ . "/$phpVersion/$platform/makedb.php");
		copy(__DIR__ . '/postupdate.php', __DIR__ . "/$phpVersion/$platform/postupdate.php");
	}
}

echo 'Dockerfile variants updated' . PHP_EOL;
