{
  cpu = [
    {
      percpu = true;
      totalcpu = true;
      collect_cpu_time = false;
      report_active = false;
    }
  ];
  disk = [
    {
      ignore_fs = [ "tmpfs" "devtmpfs" "devfs" "overlay" "aufs" "squashfs" ];
    }
  ];
  diskio = [{}];
  kernel = [{}];
  mem = [{}];
  swap = [{}];
  system = [{}];
  net = [{}];
}
