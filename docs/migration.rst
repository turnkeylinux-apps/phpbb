PHPBB Migration
===============

Note 3.2.2 migration script is broken making it impossible to migrate to 3.2.2
see https://www.phpbb.com/community/viewtopic.php?f=556&t=2453496


Steps
-----

1.  download version you wish to migrate to, unpack it and remove
    ``config.php`` ``files/`` ``images/`` and ``store/``

2.  goto webroot of install, remove all files **except** ``config.php``
    ``files/`` ``images/`` and ``store/``

3.  merge downloaded files into webroot

4.  ensure memory limit specified in ``/etc/php5/cli/php.ini`` is adequete (120M should be plenty)

5.  create a file "update.yml" with the following contents

    ```
    updater:
        type: db_only

    ```

6.  run ``php webroot/install/ db:migrate update.yml``

