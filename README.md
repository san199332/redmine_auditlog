Redmine Auditlog
-------

Provides full auditlog for user actions in Redmine instance.

### Warning
Attention this version only works on 5.x

To work with redmine version 5.0.3 add to config/application.rb:

config.active_record.yaml_column_permitted_classes = [
      Symbol,
      ActiveSupport::HashWithIndifferentAccess,
      ActiveSupport::TimeWithZone,
      Time,
      Date,
      ActiveSupport::TimeZone,
      ActionController::Parameters
    ]

How to install
-------
```
  $ cd /var/www/redmine/plugins
  $ git clone https://github.com/RealEnder/redmine_auditlog
  $ cd /var/www/redmine
  $ bundle install
  $ cd /var/www/redmine/plugins/redmine_auditlog
  $ RAILS_ENV="production" rails generate audited:install # If using PostgreSQL, add "--audited-changes-column-type jsonb" for more efficient storage
  $ cd ../..
  $ rake db:migrate RAILS_ENV="production"
```
Then restart Redmine.

How to upgrade
-------
```
  $ cd /var/www/redmine
  $ bundle install
  $ cd /var/www/redmine/plugins/redmine_auditlog
  $ RAILS_ENV="production" rails generate audited:upgrade # If using PostgreSQL, add "--audited-changes-column-type jsonb" for more efficient storage
  $ cd ../..
  $ rake db:migrate RAILS_ENV="production"
```
Then restart Redmine.

How to remove
-------
```
  $ cd /var/www/redmine
  $ rake redmine:plugins:migrate NAME=redmine_auditlog VERSION=0 RAILS_ENV=production
  $ rm -rf plugins/redmine_auditlog
```
Then restart Redmine. This will not remove audit table.


Compatible with:	Redmine 5.x  
Tested with Redmine 5.0.3

License
-------
Copyright 2022 Alexandr Antonov
This plugin is released under the GPL v3 license. See  
LICENSE for more information.

