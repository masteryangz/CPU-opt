docker run -it -v /etc/localtime:/etc/localtime:ro -v /tmp/.X11-unix:/tmp/.X11-unix -v .:/root/baseline -w /root/baseline -e DISPLAY=$DISPLAY -e GDK\_SCALE -e GDK\_DPI\_SCALE threevc/cse148wi25 /bin/bash