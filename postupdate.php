<?php
/**
 * Post-Manual Update Script
 *
 * from https://gist.github.com/mbabker/d7bfb4e1e2fbc6b7815a733607f89281
 *
 * @package    Joomla.Administrator
 *
 * @copyright  Copyright (C) 2016 Open Source Matters, Inc. All rights reserved.
 * @license    GNU General Public License version 2 or later; see LICENSE.txt
 */

/**
 * Define the application's minimum supported PHP version as a constant so it can be referenced within the application.
 */
define('JOOMLA_MINIMUM_PHP', '5.3.10');

if (version_compare(PHP_VERSION, JOOMLA_MINIMUM_PHP, '<'))
{
	die('Your host needs to use PHP ' . JOOMLA_MINIMUM_PHP . ' or higher to run this version of Joomla!');
}

/**
 * Constant that is checked in included files to prevent direct access.
 * define() is used in the installation folder rather than "const" to not error for PHP 5.2 and lower
 */
define('_JEXEC', 1);

// Load the administrator application's path constants
if (file_exists(__DIR__ . '/defines.php'))
{
	include_once __DIR__ . '/defines.php';
}

if (!defined('_JDEFINES'))
{
	define('JPATH_BASE', __DIR__);
	require_once JPATH_BASE . '/includes/defines.php';
}

require_once JPATH_BASE . '/includes/framework.php';
require_once JPATH_BASE . '/includes/helper.php';
require_once JPATH_BASE . '/includes/toolbar.php';

// Boot JApplicationAdministrator so the application references in the factory resolve correctly.
JFactory::getApplication('administrator');

// Set the component path (un)constants
define('JPATH_COMPONENT', JPATH_ADMINISTRATOR . '/components/com_joomlaupdate');
define('JPATH_COMPONENT_ADMINISTRATOR', JPATH_ADMINISTRATOR . '/components/com_joomlaupdate');
define('JPATH_COMPONENT_SITE', JPATH_SITE . '/components/com_joomlaupdate');

// Load the update component's model to run the cleanup methods
JModelLegacy::addIncludePath(JPATH_COMPONENT_ADMINISTRATOR . '/models', 'JoomlaupdateModel');

/** @var JoomlaupdateModelDefault $model */
$model = JModelLegacy::getInstance('default', 'JoomlaupdateModel');

// Make sure we got the model
if (!($model instanceof JoomlaupdateModelDefault))
{
	echo 'Could not load update component model, please check the logs for additional details.' . PHP_EOL;

	exit(1);
}

// Load up the logger
JLog::addLogger(
	array(
		'format'    => '{DATE}\t{TIME}\t{LEVEL}\t{CODE}\t{MESSAGE}',
		'text_file' => 'joomla_update.php',
	),
	JLog::INFO,
	array('Update', 'databasequery', 'jerror')
);

JLog::add('Starting manual update using postupdate', JLog::INFO, 'Update');

// Load the Joomla library and update component language files
JFactory::getLanguage()->load('lib_joomla');
JFactory::getLanguage()->load('com_joomlaupdate');

JLog::add(JText::_('COM_JOOMLAUPDATE_UPDATE_LOG_FINALISE'), JLog::INFO, 'Update');

// Finalize the update
if ($model->finaliseUpgrade() === false)
{
	echo 'Failed to finalize the upgrade, please check the logs for additional details.' . PHP_EOL;

	exit(1);
}

JLog::add(JText::_('COM_JOOMLAUPDATE_UPDATE_LOG_CLEANUP'), JLog::INFO, 'Update');

// Cleanup after the update
$model->cleanUp();

JLog::add(JText::sprintf('COM_JOOMLAUPDATE_UPDATE_LOG_COMPLETE', JVERSION), JLog::INFO, 'Update');
JLog::add('Finished manual update using postupdate', JLog::INFO, 'Update');

echo 'Update to ' . JVERSION . ' completed successfully.' . PHP_EOL;
