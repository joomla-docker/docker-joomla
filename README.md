# About this Repo

This is the Git repo of the Docker [official image](https://docs.docker.com/docker-hub/official_repos/) for [joomla](https://registry.hub.docker.com/_/joomla/). See [the Docker Hub page](https://registry.hub.docker.com/_/joomla/) for the full readme on how to use this Docker image and for information regarding contributing and issues.

The full readme is generated over in [docker-library/docs](https://github.com/docker-library/docs), specifically in [docker-library/docs/joomla](https://github.com/docker-library/docs/tree/master/joomla).

See a change merged here that doesn't show up on the Docker Hub yet? Check [the "library/joomla" manifest file in the docker-library/official-images repo](https://github.com/docker-library/official-images/blob/master/library/joomla), especially [PRs with the "library/joomla" label on that repo](https://github.com/docker-library/official-images/labels/library%2Fjoomla). For more information about the official images process, see the [docker-library/official-images readme](https://github.com/docker-library/official-images/blob/master/README.md).

---
### Build Status Badges Per Arch

| [![GitHub CI build status badge](https://github.com/joomla-docker/docker-joomla/workflows/GitHub%20CI/badge.svg)](https://github.com/joomla-docker/docker-joomla/actions?query=workflow%3A%22GitHub+CI%22) | [![amd64 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/amd64/job/joomla.svg?label=amd64)](https://doi-janky.infosiftr.net/job/multiarch/job/amd64/job/joomla) | [![arm32v5 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm32v5/job/joomla.svg?label=arm32v5)](https://doi-janky.infosiftr.net/job/multiarch/job/arm32v5/job/joomla) | [![i386 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/i386/job/joomla.svg?label=i386)](https://doi-janky.infosiftr.net/job/multiarch/job/i386/job/joomla) |
| --- | --- | --- | --- |
| [![arm32v6 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm32v6/job/joomla.svg?label=arm32v6)](https://doi-janky.infosiftr.net/job/multiarch/job/arm32v6/job/joomla) | [![arm32v7 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm32v7/job/joomla.svg?label=arm32v7)](https://doi-janky.infosiftr.net/job/multiarch/job/arm32v7/job/joomla) | [![arm64v8 build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/joomla.svg?label=arm64v8)](https://doi-janky.infosiftr.net/job/multiarch/job/arm64v8/job/joomla) | [![mips64le build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/mips64le/job/joomla.svg?label=mips64le)](https://doi-janky.infosiftr.net/job/multiarch/job/mips64le/job/joomla) |
| [![ppc64le build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/joomla.svg?label=ppc64le)](https://doi-janky.infosiftr.net/job/multiarch/job/ppc64le/job/joomla) | [![s390x build status badge](https://img.shields.io/jenkins/s/https/doi-janky.infosiftr.net/job/multiarch/job/s390x/job/joomla.svg?label=s390x)](https://doi-janky.infosiftr.net/job/multiarch/job/s390x/job/joomla) |  |

[See OS/ARCH](https://registry.hub.docker.com/_/joomla/?tab=tags) on official images.

--- 
## How to update the official docker-library/official-images repo

### First update the git repository (basic steps)
- Fork [this repository](https://github.com/joomla-docker/docker-joomla).
- Clone your forked repository to your local PC and change to the staging branch.
```shell
$ git clone git@github.com:your-name/docker-joomla.git
$ cd docker-joomla
$ git checkout staging
```
- Open the [versions-helper.json](https://github.com/joomla-docker/docker-joomla/blob/staging/versions-helper.json) file **if this is a version update**.
- Update the full version number on line [3](https://github.com/joomla-docker/docker-joomla/blob/0dd714aae69dd103e72ae519d4638b71da7c5e4f/versions-helper.json#L3) and [32](https://github.com/joomla-docker/docker-joomla/blob/0dd714aae69dd103e72ae519d4638b71da7c5e4f/versions-helper.json#L32) _(example)_.
- Run the [update.sh](https://github.com/joomla-docker/docker-joomla/blob/staging/update.sh) script once.
```shell
$ sudo chmod +x update.sh
$ ./update.sh
```
- **OR** make what ever changes you think will improve the images
- Make a commit message with **every change**.
```shell
$ git commit -am"Update images of Joomla! x.x.x to x.x.x"
```
- Push the changes to your repository.
```shell
$ git push origin staging
```
- Make a pull request against the staging branch.
- **Done!**

### Maintainers must then do the following
- Continue only if all checks are passed with [du-diligence](https://en.wikipedia.org/wiki/Due_diligence) 
- Merge the pull request into staging
- Merge the staging branch into the master branch
- Again continue only if all checks are passed with [du-diligence](https://en.wikipedia.org/wiki/Due_diligence)
- Clone the master branch of [this repository](https://github.com/joomla-docker/docker-joomla/tree/master) to your PC and change to the master branch.
```shell
$ git clone git@github.com:joomla-docker/docker-joomla.git
$ cd docker-joomla
$ git checkout master
```
- Run the [generate-stackbrew-library.sh](https://github.com/joomla-docker/docker-joomla/blob/staging/generate-stackbrew-library.sh).
```shell
$ sudo chmod +x generate-stackbrew-library.sh
$ ./generate-stackbrew-library.sh
```
- This will give an output of all the new values needed in the official images (validate the output)
- _The easy way to move this output of this file to the official images can be done in the following way._
- Open the [forked official-images](https://github.com/joomla-docker/official-images) and click on the **Fetch Upstream** button.
- Then click on **Fetch and Merge** while being in the master branch.
- Clone the master branch of [this repository](https://github.com/joomla-docker/official-images/tree/master) to your PC.
```shell
$ git clone git@github.com:joomla-docker/official-images.git
$ cd official-images
$ git checkout master
```
- Create a new branch called **joomla**
```shell
$ git checkout -b joomla
```
- At this point you should have two directories **docker-joomla** and **official-images**
- **Preferably** in the _same directory_ so you can do the following.
- Change back to the **docker-joomla** repository.
```shell
$ cd ../docker-joomla
```
- Run the following command, targeting the Joomla library file in the **official-images** directory with the output:
```shell
$ ./generate-stackbrew-library.sh > ../official-images/library/joomla
```
- Change again to the **official-images** repository.
```shell
$ cd ../official-images
```
- Make a commit that will best reflect a summary of the changes.
```shell
$ git commit -am"Update Joomla!"
```
- Push the changes to up our _**forked official-images**_
```shell
$ git push -u origin joomla
```

### Official Images About to Update
- Open a pull request from our _**forked official-images**_ to [official-images](https://github.com/docker-library/official-images).
- Use the following convention in the message, [check past](https://github.com/docker-library/official-images/pull/10902) to see convention.
```txt
Changes:

- joomla-docker/docker-joomla@54a82e4: Update images of Joomla! 4.0.2 to 4.0.3
- joomla-docker/docker-joomla@f87bc00: Update version of Joomla! 4.0.2 to 4.0.3
- joomla-docker/docker-joomla@f36a82a: Update images of Joomla! 3.10.1 to 3.10.2
- joomla-docker/docker-joomla@4bc3c7b: Update version of Joomla! 3.10.1 to 3.10.2
```
- Basically denoting each commit to [our master branch](https://github.com/joomla-docker/docker-joomla/tree/master) since the last update to the official images.
- Once this is done, the maintainers of the [official Docker images](https://github.com/docker-library/official-images) takes over.
- Should there be any issue which you can't resolve, reach out to the [other maintainers](https://github.com/joomla-docker/docker-joomla/graphs/contributors).
- Done!

> The [current maintainers](https://github.com/joomla-docker/docker-joomla/blob/master/maintainers.json) of the official images. Let us know if you have any questions.