source $1
workdir=$NETWORK_ID
rm -Rf $workdir

mkdir $workdir || true
cd $workdir

../scripts/generate-network-files node-files $NETWORK_ID.$DOMAIN $NETWORK_ID $NODE_COUNT

mkdir terraform
cp ../GCE/* ./terraform

cat << FOO >> ./terraform/config.tf
variable "cridentials_file"   { default = "~/.gcp-account.json" }
variable "tag"         		    { default = "$NETWORK_ID" }
variable "project"        	  { default = "developer-222401" }
variable "region"             { default = "europe-west1" }
variable "zone"               { default = "europe-west1-b" }
variable "node_count"         { default = "$NODE_COUNT" }
variable "domain"             { default = "$DOMAIN" }
variable "machine_type"       { default = "n1-highcpu-$CPU_PER_NODE" }
variable "disk_size"          { default = 30 }
variable "subnet"             { default = "10.8.0.0/26" }
variable "gitcrypt_key_file"  {}
FOO

cat node-files/*/rnode.conf.d/*-node.conf | grep validator-public-key | \
awk  '{print $2}' | rev | cut -c2- | rev | cut -c2- | \
awk '{print $0 ", 50000000000000"}' >> genesis_bonds.txt

cp ../bootstrap.sh ./
