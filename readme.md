Project structure

clickhouse-staging-cluster/
├── docker-compose.yml
├── keeper01/keeper_config.xml
├── keeper02/keeper_config.xml
├── keeper03/keeper_config.xml
├── ch01/
│   ├── config.d/
│   │   ├── remote-servers.xml
│   │   ├── zookeeper.xml
│   │   ├── macros.xml
│   │   ├── network-and-logging.xml
│   │   ├── interserver.xml
│   │   └── backup_disks.xml
│   └── users.d/
│       └── default.xml
└── ch02/
    ├── config.d/
    │   ├── remote-servers.xml
    │   ├── zookeeper.xml
    │   ├── macros.xml
    │   ├── network-and-logging.xml
    │   ├── interserver.xml
    │   └── backup_disks.xml
    └── users.d/
        └── default.xml
