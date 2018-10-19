# vitess migration

As of now, there is no vitess documentation on how to do a hot-migration. This is a PoC that does that. We use innobackupex to create a backup. This is not (yet) officially supported by vitess.

## Concept

* On the donor host: Create a backup using `innobackupex`.
* stream/copy that backup to the vitess master
* restore the backup (shutdown mysqld)
* apply vitess `init_db.sql` dump
* start replication

We do the same for the `vitess-master` to `vitess-replica` migration.

Once we're done with that vitess will take over the management and we should be able to use all of vitess' functionallity. (only Backups are tested at the moment).

## Set up

The following step-by-step guide is derived from the official the [vitess guide](https://github.com/vitessio/vitess/tree/master/examples/compose)

```

$ docker-compose up -d

# once consul & vtctld is ready
$ ./lvtctl.sh ApplySchema -sql "$(cat create_test_table.sql)" test_keyspace

# start vtgate
$ docker-compose up -d

$ ./migrate.sh from 1

# test if mysql came up properly and data is present
$ docker-compose exec vttablet1 mysql -h 127.0.0.1 -uroot vt_test_keyspace -e "select * from messages"
> +------+-----------------+---------+
> | page | time_created_ns | message |
> +------+-----------------+---------+
> |    1 |  20181019085053 | baz     |
> +------+-----------------+---------+

# this should yield "Slave IO/SQL Running: Yes"
$ ./replicate.sh 1 from root root

# insert to "from" database
$ docker-compose exec from mysql -h 127.0.0.1 -uroot -proot vt_test_keyspace -e "insert into messages VALUES (2, NOW(), 'foo')"

# check again if stuff replicated properly
$ docker-compose exec vttablet1 mysql -h 127.0.0.1 -uroot vt_test_keyspace -e "select * from messages"
> +------+-----------------+---------+
> | page | time_created_ns | message |
> +------+-----------------+---------+
> |    1 |  20181019085053 | baz     |
> +------+-----------------+---------+
> |    2 |  20181019094214 | foo     |
> +------+-----------------+---------+



# create replicas
$ ./migrate.sh vttablet1 2
$ ./migrate.sh vttablet1 3

# start replication with root user / nopasswd
$ ./replicate.sh 2 vttablet1 root ''
$ ./replicate.sh 3 vttablet1 root ''

# use vitess client script to test sharding (run it twice)
$ ./client.sh
$ ./client.sh

$ docker-compose restart vttablet2 vttablet3
# once the vttablet2/3 containers come up
# vttablet will take care about the replication 
# (it uses the vt_repl user)

# run client again to check repl (after a few seconds)
./client.sh

# backup data:
# vtctl tells vtctld to take backups
# the respective vttablet will actually do the backup

$ docker-compose exec vttablet1 bash -c "vtctl \$TOPOLOGY_FLAGS Backup test-2"
$ docker-compose exec vttablet1 bash -c "vtctl \$TOPOLOGY_FLAGS Backup test-3"

$ docker-compose exec vttablet2 bash -c "ls -la /vt/vtdataroot/backups/test_keyspace/0"
$ docker-compose exec vttablet3 bash -c "ls -la /vt/vtdataroot/backups/test_keyspace/0"

```


## lessons learned

Vitess uses `--binlog-format=statement` see [here](https://vitess.io/user-guide/vitess-replication/). We use `ROW` format.

* Vitess can *NOT* create a backup from a master tablet.
* Vitess Backups require to stop the `mysqld` process!
* Vitess uses a different directory layout for the mysql data. See `cat /vt/vtdataroot/vt_000000000${TABLET_ID}/my.cnf` for reference. Especially `tablespaces, innodb and bin/relay logs` are in a different location
* vitess does not support innobackupex/xtrabackup yet, see [vitess/#3957](https://github.com/vitessio/vitess/issues/3957) but with this approach it will work (downside: master won't be auto-replicated after container restart)
* vttablet takes care about the replication once the mysqld comes up. This is *ONLY* true for replicas. masters need manual action for that


## todo

* bake binaries into Vitess images (innobackupex, socat, nc..)
* stream backup instead of copying it over using socat:
  * donor: `nohup socat tcp-l:4565,reuseaddr,fork system:"innobackupex --stream=xbstream --ftwrl-wait-threshold=40 --ftwrl-wait-query-type=all --ftwrl-wait-timeout=180 --kill-long-queries-timeout=20 --kill-long-query-type=all $DATADIR"`
  * receiver: `nc -i 10 $TARGET_HOST $TARGET_PORT | pv -b | xbstream -x -C $DATADIR`
* get rid of `sleep N`

