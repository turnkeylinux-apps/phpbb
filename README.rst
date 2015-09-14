phpBB - Community Forum Solution
================================

`phpBB`_ is used by millions, making it the most used Open Source forum
solution in the world. phpBB incorporates a professional-quality modular
design, high security, multiple-language interface and an extensive
administration panel, which allows the customization of even the most
intricate features.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- phpBB configurations:
   
   - Installed from package management. See /var/www for links to file
     paths.
   - Uploading of avatars is supported, and enabled by default.
   - Setup an example forum, including welcome post displaying default
     login credentials.

- SSL support out of the box.
- `Adminer`_ administration frontend for MySQL (listening on port
   12322 - uses SSL).
- Postfix MTA (bound to localhost) to allow sending of email
  (e.g., password recovery, notifications).
- Webmin modules for configuring Apache2, PHP and MySQL.

- Note, you may not be able to access the moderator control panel if you
  delete all forums (e.g., the example forum). See this `thread`_ for
  details.

Credentials *(passwords set at first boot)*
-------------------------------------------

-  Webmin, SSH, MySQL, Adminer: username **root**
-  phpBB: username **admin**


.. _phpBB: http://www.phpbb.com
.. _TurnKey Core: https://www.turnkeylinux.org/core
.. _Adminer: http://www.adminer.org/
.. _thread: https://www.turnkeylinux.org/forum/support/20091229/phpbb-admin-not-authorised-access-area-moderator-control-panel
