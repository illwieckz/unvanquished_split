#! /bin/sh

# Author:  Thomas DEBESSE <dev@illwieckz.net>
# License: CC0 1.0 [https://creativecommons.org/publicdomain/zero/1.0/]

# It's recommended to run filters in tmpfs mounted point to speed up I/Os
# and to save your precious SSD
#
# Example:
#
#  mkdir -p /mnt/tmpfs
#  mount -t tmpfs -o size=2G tmpfs /mnt/tmpfs
#  export TMPDIR='/mnt/tmpfs'
#
# It's even better and faster to do everything on that tmpfs mounted point
#
#  cd /mnt/tmpfs
#  git clone https://github.com/illwieckz/unvanquished_split.git
#  cd unvanquished_split
#  ./extract_daemon.sh

if [ -z "${TMPDIR}" ]
then
	temp_dir="$(mktemp -d "/tmp/extract.XXXXXXXX}")"
else
	temp_dir="$(mktemp -d "${TMPDIR}/extract.XXXXXXXX")"
fi

work_dir="$(pwd)/extract_daemon"
repo_dir="${work_dir}/repo"
list_dir="${work_dir}/list"

bin_dir="$(pwd)/bin"
PATH="${PATH}:${bin_dir}"

unvanquished_remote='git@github.com:Unvanquished/Unvanquished.git'
daemon_remote='git@github.com:illwieckz/Daemon.git'
daemon_mirror="${repo_dir}/Daemon.git"
unvanquished_mirror="${repo_dir}/Unvanquished.git"
daemon_local="${repo_dir}/Daemon"
final_subdir='daemon'
main_branch='master'
subdir_list="${list_dir}/subdir_list.txt"
all_list="${list_dir}/all_list.txt"
moved_list="${list_dir}/moved_list.txt"
previous_list="${list_dir}/previous_list.txt"
movable_list="${list_dir}/movable_list.txt"

# there is no need to care about it
# pivot_commit='38f0b762c14cb2df86fd5baa1d7e9624d75d579d'

mkdir -p "${work_dir}"
mkdir -p "${repo_dir}"
mkdir -p "${list_dir}"

cat > "${subdir_list}" <<-EOF
	${final_subdir}
	src/common
	src/engine
	src/libs/crunch
	src/libs/detour
	src/libs/fastlz
	src/libs/findlocale
	src/libs/minizip
	src/libs/openexr
	src/libs/pdcurses
	src/libs/recast
	src/libs/tinyformat
	src/libs/gettext
	src/libs/zlib
EOF

# unwrap tools
./write_scripts.sh

cd "${work_dir}"

printf '== mirror original tree ==\n'

if ! [ -d "${unvanquished_mirror}" ]
then
	git clone --mirror "${unvanquished_remote}" "${unvanquished_mirror}"
fi

(
	cd "${unvanquished_mirror}"
	switchBranch "${main_branch}"
	git fetch --all

)

printf '== mirror new tree ==\n'

git clone --mirror "${unvanquished_mirror}" "${daemon_mirror}"

(
	cd "${daemon_mirror}"
	switchBranch "${main_branch}"

	printf '== drop pull requests ==\n'

	# we will not be able to push pull requests, so, we can drop them
	git for-each-ref --format='%(refname)' 'refs/pull/' \
	| xargs -P1 -n1 git update-ref -d

	# remove some 'reviewable' stuff that mess repository
	# see https://github.com/Unvanquished/Unvanquished/pull/828
	# and https://reviewable.io/reviews/unvanquished/unvanquished/828
	git for-each-ref --format='%(refname)' 'refs/reviewable/' \
	| xargs -P1 -n1 git update-ref -d

	printf '== list all files from repository ==\n'

	listAllFiles > "${all_list}"

	printf '== list all files from engine subdirectories ==\n'

	grepAllFilesInAllSubdirs "${all_list}" "${subdir_list}" > "${movable_list}"

	printf '== list all previous files to subdirectories ==\n'

	listPreviousFilesInAllBranches "${movable_list}" > "${previous_list}"
	
	printf '== list all moved files from subdirectories ==\n'

	cat "${movable_list}" "${previous_list}" \
	| grep -v "^${final_subdir}/" \
	| sort -u > "${moved_list}"

	printf '== move files in final subdirectory ==\n'

	# filter_dir is automatically deleted by git filter-branch
	filter_dir="$(mktemp -d "${temp_dir}/filter.XXXXXXXX")"
	git filter-branch -d "${filter_dir}" -f \
		--tree-filter "moveFilter '${final_subdir}' '${moved_list}'" \
		--tag-name-filter cat -- --all


	git for-each-ref --format='%(refname)' 'refs/original/' \
	| xargs -P1 -n1 git update-ref -d

	printf '== extract subdirectory ==\n'

	# filter_dir is automatically deleted by git filter-branch
	filter_dir="$(mktemp -d "${temp_dir}/filter.XXXXXXXX")"
	git filter-branch -d "${filter_dir}" -f \
		--subdirectory-filter "${final_subdir}" \
		--tag-name-filter cat -- --all

	git for-each-ref --format='%(refname)' 'refs/original/' \
	| xargs -P1 -n1 git update-ref -d

	printf '== garbage collect ==\n'

	git reflog expire --expire=now --all
	git gc --prune=now --aggressive

	printf '== push new repository ==\n'

	git push -f --mirror "${daemon_remote}"
)

printf '== clone local repository ==\n'

git clone "${daemon_mirror}" "${daemon_local}"

(
	cd "${daemon_local}"
	git checkout "${main_branch}"

	printf '== set new origin ==\n'

	git remote remove origin
	git remote add origin "${daemon_remote}"

	printf '== readd submodules ==\n'

	git checkout -b 'submodules' "${main_branch}"

	git rm libs/breakpad
	git rm libs/recastnavigation

	git submodule add https://github.com/Unvanquished/breakpad.git libs/breakpad
	git submodule add https://github.com/Unvanquished/recastnavigation.git libs/recastnavigation

	git commit -m 'readd submodules'

	git checkout "${main_branch}"
	git merge 'submodules'

	printf '== push submodules ==\n'

	git push origin 'submodules'
	git push origin "${main_branch}"
)

#EOF
