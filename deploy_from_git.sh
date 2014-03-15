#!/bin/sh
#
# deploy_from_git.sh
#
# Copyright (C) 2010 - 2014	Andrew Clayton <andrew@digital-domain.net>
#
# This software is licensed under the GNU General Public License Version 2
# See COPYING
#
# This is a script for deploying web applications from git repositories.
#

function display_usage()
{
	echo "Usage: deploy_from_git.sh [-t <target>] <SHA1 | HEAD | dirty>"
}

function create_release_copy()
{
	echo -en "\033[1;33m[Remote]\033[0m Creating a copy of the current release: "
	echo -e "\033[0;33m${RELEASES[0]} \033[1;37m->\033[0;33m $TREE"
	ssh $HOST cp -a $REMOTE_REL_DIR/${RELEASES[0]} $REMOTE_DEPLOY_DIR
}

function create_symlink()
{
	echo -e "\033[1;33m[Remote]\033[0m Creating symlink: \033[0;33mcurrent \033[1;37m->\033[0m \033[0;33mreleases/$TREE\033[0m"
	ssh $HOST "cd $REMOTE_APP_DIR && ln -snf releases/$TREE current"
}

function push_up_tree()
{
	EXCLUDES_A="$HOME/.config/deploy_from_git/`basename \`pwd\``.$TARGET.excludes"
	EXCLUDES="$HOME/.config/deploy_from_git/`basename \`pwd\``.excludes"

	if [[ -f $EXCLUDES_A ]] && [[ $TARGET ]]; then
		EARG="--exclude-from=$EXCLUDES_A"
	elif [[ -f $EXCLUDES ]]; then
		EARG="--exclude-from=$EXCLUDES"
	else
		EARG=""
	fi

	echo -e "\033[1;34m[Local ]\033[0m Pushing up \033[0;34m$TREE\033[0m"
	rsync -rtlz -q --delete --stats $EARG -e ssh $LOCAL_DEPLOY_DIR/ $HOST:$REMOTE_DEPLOY_DIR
	# Ensure that file/directory permissions are set right.
	ssh $HOST "find $REMOTE_DEPLOY_DIR -type f -exec chmod 660 {} \; && find $REMOTE_DEPLOY_DIR -type d -exec chmod 2770 {} \;"
}

function post_run()
{
	POSTRUN_A="$HOME/.config/deploy_from_git/`basename \`pwd\``.$TARGET.post"
	POSTRUN="$HOME/.config/deploy_from_git/`basename \`pwd\``.post"

	if [[ -f $POSTRUN_A ]] && [[ $TARGET ]]; then
		echo -e "\033[1;34m[Local ]\033[0m Reading commands from \033[0;34m$POSTRUN_A\033[0m"
		source $POSTRUN_A
	elif [[ -f $POSTRUN ]] && [[ ! $TARGET ]]; then
		echo -e "\033[1;34m[Local ]\033[0m Reading commands from \033[0;34m$POSTRUN\033[0m"
		source $POSTRUN
	fi
}

function clean_up()
{
	echo -e "\033[1;34m[Local ]\033[0m Removing local deploy directory..."
	rm -rf $LOCAL_DEPLOY_DIR
}


while getopts "ht:" OPTION; do
	case "$OPTION" in
		h)
			display_usage
			exit 0
			;;
		t)
			TARGET=$OPTARG
			;;
	esac
done

# Get the commit into $1
shift $(($OPTIND - 1))
if [[ ! $1 ]]; then
	echo "At least a commit id must be given"
	display_usage
	exit -1
fi

TREEISH=$1
# If we are given HEAD or dirty, convert that into a commit id
if [[ $TREEISH = HEAD ]] || [[ $TREEISH = dirty ]]; then
	COMMIT=`git log -1 | head -n 1 | cut -d " " -f 2`
else
	COMMIT=$TREEISH
fi

# Check if we got a sufficiently long commit id (8 characters or more)
if [[ ${#COMMIT} -lt 8 ]]; then
	echo -e "\033[1;31m[Error ] \033[0;31m$COMMIT \033[1;37mis too short. Provide at least the first 8 characters of the commit id.\033[0m"
	exit -1
fi

if [[ ! $TARGET ]]; then
	CONFIG_FILE="`basename \`pwd\``.config"
else
	CONFIG_FILE="`basename \`pwd\``.$TARGET.config"
fi

CONFIG="$HOME/.config/deploy_from_git/$CONFIG_FILE"
if [[ ! -f $CONFIG ]]; then
	echo -e "\033[1;31m[Error ]\033[1;37m Could not open config file\033[0;31m $CONFIG\033[0m"
	exit -1
else
	echo -e "\033[1;34m[Local ]\033[0m Using config file: \033[0;34m$CONFIG\033[0m"
	source $CONFIG
fi

# Take the first 8 characters of the commit id
TREE=${COMMIT:0:8}
REMOTE_REL_DIR="$REMOTE_APP_DIR/releases"

#
# Check if we have NR_RELEASES set, if not, set it to 2, if it is set
# but less than 2, set it to 2.
#
if [[ ! $NR_RELEASES ]] || [[ $NR_RELEASES -lt 2 ]]; then
	echo -e "\033[1;34m[Local ]\033[0m NR_RELEASES not set or less than 2. Using \033[0;34m2\033[0m as default."
	NR_RELEASES=2
else
	echo -e "\033[1;34m[Local]\033[0m NR_RELEASES set to \033[0;34m$NR_RELEASES\033[0m in config file."
fi

#
# Create a temporary directory to hold the git archive
#
LOCAL_DEPLOY_DIR="`mktemp -d /tmp/deploy_from_git.XXXXX`"
if [[ ! -d $LOCAL_DEPLOY_DIR ]]; then
	echo -e "\033[1;31m[Error ]\033[1;37m Local git deploy directory was not created.\033[0m"
	exit -1
fi
echo -e "\033[1;34m[Local ]\033[0m Created local deploy directory \033[0;34m$LOCAL_DEPLOY_DIR\033[0m"

echo -e "\033[1;34m[Local ]\033[0m Extracting \033[0;34m$TREE\033[0m from repository..."
#
# Copy out specified tree to the temporary directory
#
git archive --format=tar $TREE | (cd $LOCAL_DEPLOY_DIR && tar -xf -)
if [ $? -ne 0 ]; then
	echo -e "\033[1;31m[Error ]\033[1;37m git archive command failed.\033[0m"
	clean_up
	exit -1
fi
#
# Check if we were given dirty as the treeish
# If so, patch our archive with the uncommitted changes
#
if [[ $TREEISH = dirty ]]; then
	echo -e "\033[1;34m[Local ]\033[0m Patching archive..."
	git diff | (cd $LOCAL_DEPLOY_DIR && patch -p1)
	TREE=$TREE-dirty
fi
REMOTE_DEPLOY_DIR="$REMOTE_REL_DIR/$TREE"

#
# Deal with any submodules. If there are submodules,
# we just take the HEAD
#
if [ -f .gitmodules ]; then
	REPO_DIR=`pwd`
	SUB_PATHS=`grep "path = " .gitmodules | cut -d = -f 2`

	for sub_path in $SUB_PATHS; do
		echo -e "\033[1;34m[Local ]\033[0m Processing submodule \033[0;34m$sub_path\033[0m"
		cd $sub_path
		git archive --format=tar --prefix=$sub_path/ HEAD | (cd $LOCAL_DEPLOY_DIR && tar -xf -)

		if [ $? -ne 0 ]; then
			echo -e "\033[1;31m[Error ]\033[1;37m git archive command failed for submodule \033[0;31m$sub_path\033[0m"
			cd $REPO_DIR
			clean_up
			exit -1
		fi

		cd $REPO_DIR
	done
fi

echo -e "\033[1;33m[Remote]\033[0m Checking for existing releases on\033[0;33m $HOST\033[0m..."
#
# Get a list of current releases on the server and store them in an
# array. We sort the entries in time order. Newest first.
#
RELEASES=(`ssh $HOST ls --sort=time $REMOTE_REL_DIR 2> /dev/null`)
echo -e "\033[1;33m[Remote]\033[0m Found ${#RELEASES[@]} release(s)."
LSEQ=$((${#RELEASES[@]} - 1))
TAE=""
for rel in `seq -s " " 0 $LSEQ`; do
	echo -e "\t\033[0;33m${RELEASES[$rel]}\033[0m"
		#
		# Check if the tree already exists on server
		#
		if [[ ${RELEASES[$rel]} = $TREE ]]; then
			TAE=$TREE
		fi
done

#
# If we already have the dirty tree up, then we want to allow
# to overwrite it.
#
if [[ $TAE != "" ]] && [[ $TREEISH != dirty ]]; then
	echo -e "\033[1;31m[Error ]\033[0;31m $TREE \033[1;37malready on server.\033[0m"
	clean_up
	exit -1
fi

if [ $LSEQ -eq -1 ]; then
	#
	# First deploy. No previous releases
	#
	echo -e "\033[1;33m[Remote]\033[0m Creating remote deploy directory \033[0;33m$REMOTE_DEPLOY_DIR\033[0m..."
	ssh $HOST mkdir -p $REMOTE_DEPLOY_DIR
	push_up_tree
	create_symlink
elif [[ $TREEISH = dirty ]] && [[ $TAE != "" ]]; then
	#
	# If we are using a dirty tree that is already up.
	# we just want to update it. Also create the symlink just
	# to be safe.
	#
	push_up_tree
	create_symlink
else
	#
	# Subsequent deploys
	#
	NREL=$(($NR_RELEASES - 1))
	if [ $LSEQ -ge $NREL ]; then
		#
		# We have NR_RELEASES or more. Remove the old ones.
		#
		for rel in `seq -s " " $NREL $LSEQ`; do
			echo -en "\033[1;33m[Remote]\033[0m Removing old release: "
			echo -e "\033[0;33m${RELEASES[$rel]}\033[0m..."
			ssh $HOST rm -rf $REMOTE_REL_DIR/${RELEASES[$rel]}
		done
	fi
	create_release_copy
	push_up_tree
	create_symlink
fi

post_run
clean_up
exit 0
