aws-ec2-ebs-automatic-encrypted-snapshot-bash
===================================

####Bash script for Automatic encrypted EBS Snapshots on Amazon Web Services (AWS)

Written by Sally Lehman

Adapted from [CaseyLabs/aws-ec2-ebs-automatic-snapshot-bash](https://github.com/CaseyLabs/aws-ec2-ebs-automatic-snapshot-bash)

===================================

**How it works:**
ebs-snapshot.sh will:
- Determine the instance ID of the EC2 server on which the script runs
- Gather a list of all volume IDs attached to that instance
- Take a snapshot of each attached volume
- Copy snapshots into encrypted snapsnots
- Delete unencrypted snapshots

Pull requests greatly welcomed!

===================================

**REQUIREMENTS**

**IAM User:** This script requires that new IAM user credentials be created, with the following IAM security policy attached:

```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1426256275000",
            "Effect": "Allow",
            "Action": [
                "ec2:CreateSnapshot",
                "ec2:CreateTags",
                "ec2:DeleteSnapshot",
                "ec2:DescribeSnapshots",
                "ec2:DescribeVolumes"
            ],
            "Resource": [
                "*"
            ]
        }
    ]
}
```
<br />

**AWS CLI:** This script requires the AWS CLI tools to be installed.

First, make sure Python pip is installed:
```
# Ubuntu
sudo apt-get install python-pip -y

# Red Hat/CentOS
sudo yum install python-pip -y
```
Then install the AWS CLI tools: 
```
sudo pip install awscli
```
Once the AWS CLI has been installed, you'll need to configure it with the credentials of the IAM user created above:

```
sudo aws configure

AWS Access Key ID: (Enter in the IAM credentials generated above.)
AWS Secret Access Key: (Enter in the IAM credentials generated above.)
Default region name: (The region that this instance is in: i.e. us-east-1, eu-west-1, etc.)
Default output format: (Enter "text".)```
```
<br />

**Install Script**: Download the latest version of the snapshot script and make it executable:
```
cd ~
wget https://raw.githubusercontent.com/rothsa/aws-ec2-ebs-automatic-snapshot-bash/master/ebs-snapshot.sh
chmod +x ebs-snapshot.sh
mkdir -p /opt/aws
sudo mv ebs-snapshot.sh /opt/aws/
```

You should then setup a cron job in order to schedule a nightly backup. Example crontab jobs:
```
55 22 * * * root  AWS_CONFIG_FILE="/root/.aws/config" /opt/aws/ebs-snapshot.sh

# Or written another way:
AWS_CONFIG_FILE="/root/.aws/config" 
0 */3 * * * root  /opt/aws/ebs-snapshot.sh
```
Due to the frequency by which snapshot creations in AWS fail, this should be run frequently, and regular
checks should be done to ensure that there is a backup available that is sufficiently recent.

To manually test the script:
```
sudo /opt/aws/ebs-snapshot.sh
```
