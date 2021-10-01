#!/bin/sh
#
#  hack to get PostgreSQL password in opennsa.conf
#
sed -e "s:%POSTGRES_PASSWORD%:$POSTGRES_PASSWORD:" /config/opennsa.conf >/tmp/opennsa.conf
#
# extend python path to enable loading of custum backends
#
export PYTHONPATH=/backends:$PYTHONPATH
#
# start OpenNSA with the temporary config file created above
#
exec twistd -ny /config/opennsa.tac
