# xhost +localhost
docker run -it -e DISPLAY=docker.for.mac.host.internal:0 -v /etc/localtime:/etc/localtime:ro -v /tmp/.X11-unix:/tmp/.X11-unix -v .:/root/baseline -w /root/baseline -e GDK_SCALE -e GDK_DPI_SCALE threevc/cse148wi25 /bin/bash
