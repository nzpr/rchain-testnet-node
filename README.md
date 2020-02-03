You can wipe out existing network and reestablish a new one by running

```bash
terraform destroy
```
followed by 
```bash
terraform apply
```
from inside resources-tf.{network_name} folder. This requires access to Google Cloud Engine and properly confugired gcloud and terraform.

You can run nodes instances as preemptible VMs (which are considerably cheaper) when you need to make a short test. 
But their availability is not guaranteed.

To run preemptible instances (default), use in hosts.tf
```bash
preemptible       = true
automatic_restart = false
```
for usual one change config to
```bash
preemptible       = false
automatic_restart = true
```

