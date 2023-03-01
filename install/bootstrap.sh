#!/bin/bash
##################################################################
# Installs Filecoin Client Tools on Ubuntu Linux 
##################################################################
. $(dirname $(realpath $0))"/../lotus/filecoin-tools-common.sh"

ulimit -n 1048576
export HOME=/root
PROJECT_HOME=$(dirname $(realpath $0))/..
BOOST_PATH=$HOME/.boost

################################
# Main client stack setup/test
# script should be downloaded standalone, will pull down repos for bootstrapping.
################################
function bootstrap() {
          cd /tmp
          echo "## Installing Ubuntu package dependencies..." 
          curl -o- https://raw.githubusercontent.com/frank-ang/filecoin-data-onboarding-tools/master/aws/filecoin-ubuntu-prereqs.sh run | bash
          
          apt update
          apt install -y unzip
          echo "Installing AWS CLI v2..."
          curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
          unzip -q awscliv2.zip
          ./aws/install
          echo "## AWS dependencies installed."

          echo "## Downloading filecoin data onboarding tools repo"
          cd $PROJECT_HOME
          git clone https://github.com/frank-ang/filecoin-data-onboarding-tools.git
          cd ./filecoin-data-onboarding-tools && git fetch && git switch test

          echo "Setting up Filecoin client tools..."
          cd $PROJECT_HOME/filecoin-data-onboarding-tools/lotus
          nohup ./filecoin-tools-setup.sh run >> /var/log/filecoin-tools-setup.log 2>&1 &
}
