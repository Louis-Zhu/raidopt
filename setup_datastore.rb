require 'rubygems'
require 'rbvmomi'
require './vm_utils'
require 'highline/import'
require 'pp'

def delete_array(host)
  system "ssh root@black 'cd /opt/lsi/storcli; ./storcli /c0/vall del'"

  host.configManager.storageSystem.RescanAllHba
  host.configManager.storageSystem.RescanVmfs
  host.configManager.storageSystem.RefreshStorageSystem
end

def create_array(host, disks, raid_level, strip_size, read_policy, write_policy, io_policy)
  # enclosure # is 252
  # 840 drives are 0-3
  # 830 drives are 4-7
  if disks == "8"
    drive_numbers = "0-7"
    num_drives = 8
  elsif disks == "4x830"
    drive_numbers = "4-7"
    num_drives = 4
  elsif disks == "4x840"
    drive_numbers = "0-3"
    num_drives = 4
  end

  if read_policy == "normal"
    read_ahead = "nora"
  elsif read_policy == "ahead"
    read_ahead = "ra"
  end

  if write_policy == "write-back"
    cache_policy = "awb"
  elsif write_policy == "write-thru"
    cache_policy = "wt"
  end

  if raid_level == "00" || raid_level == "10" || raid_level == "50" || raid_level == "60"
    pdperarray = "pdperarray=#{num_drives/2}"
  else
    pdperarray = ""
  end


  cmd = "ssh root@black 'cd /opt/lsi/storcli; ./storcli /c0 add vd type=raid#{raid_level} size=all name=test drives=252:#{drive_numbers} pdcache=on #{cache_policy} #{read_ahead} #{io_policy} strip=#{strip_size} #{pdperarray}'"
  fail "#{cmd} failed" unless system cmd

  host.configManager.storageSystem.RescanAllHba
  host.configManager.storageSystem.RescanVmfs
  host.configManager.storageSystem.RefreshStorageSystem
end

def mark_array_as_ssd
  array_device_id = `ssh root@black 'esxcli storage nmp device list | grep ^naa'`
  array_device_id.chomp!
  fail "didn't find raid device!" if array_device_id == ""
  puts "ssh root@black 'esxcli storage nmp satp rule add --satp=VMW_SATP_LOCAL --device=#{array_device_id} --option=\"enable_local enable_ssd\"'"
  system "ssh root@black 'esxcli storage nmp satp rule add --satp=VMW_SATP_LOCAL --device=#{array_device_id} --option=\"enable_local enable_ssd\"'"
  puts "ssh root@black 'esxcli storage core claiming unclaim --type=device --device=#{array_device_id}'"
  system "ssh root@black 'esxcli storage core claiming unclaim --type=device --device=#{array_device_id}'"
  puts "ssh root@black 'esxcli storage core claimrule load'"
  system "ssh root@black 'esxcli storage core claimrule load'"
  puts "ssh root@black 'esxcli storage core claiming reclaim -d #{array_device_id}'"
  system "ssh root@black 'esxcli storage core claiming reclaim -d #{array_device_id}'"
  puts "ssh root@black 'esxcli storage core claimrule run'"
  system "ssh root@black 'esxcli storage core claimrule run'"
  puts "ssh root@black 'esxcli storage core device list -d #{array_device_id}' | grep '^   Is SSD: true$'"
  status = `ssh root@black 'esxcli storage core device list -d #{array_device_id}' | grep '^   Is SSD: true$'`
  puts "status: #{status}"
  status.chomp!
  fail "failed to mark array as ssd" unless status == "   Is SSD: true"
end



raise "Invalid args: 8|4x830|4x840 0|5|6|10|50|60 64|128|256|512|1024 normal|ahead write-back|write-thru cached|direct" unless ARGV.size == 6

password = 'temppassword'
#password = ask("password?") {|q| q.echo = false}
$vim = VIM.connect host: 'vc', user: 'root', password: password, insecure: true
dc = $vim.serviceInstance.find_datacenter("dc1") or fail "datacenter not found"
black_host = dc.hostFolder.children.first.host.find {|host| host.name.start_with? 'black' }
raid_ds = dc.find_datastore('local-black-ssd-raid-test')
if raid_ds
  puts "found datastore #{raid_ds.name}"
  puts "shutting down and deleting vms on #{raid_ds.name}"
  raid_ds.vm.each {|vm|
    puts "Found #{vm.name}, powering off"
    vm.PowerOffVM_Task.wait_for_completion rescue nil
    puts "Deleting #{vm.name}"
    vm.Destroy_Task.wait_for_completion
    puts "#{vm.name} deleted"
  }

  puts "removing datastore"
  raid_ds.host.first.key.configManager.datastoreSystem.RemoveDatastore(:datastore => raid_ds)

  puts "deleting array"
  delete_array(black_host)

end


begin
  create_array(black_host, *ARGV)
rescue
  delete_array(black_host)
  create_array(black_host, *ARGV)
end

puts "Marking new array as SSD in esx"
mark_array_as_ssd

# http://pubs.vmware.com/vsphere-55/index.jsp#com.vmware.wssdk.pg.doc/PG_Storage.10.8.html?path=7_0_0_1_7_6_1#1141616
black_host.configManager.storageSystem.RescanAllHba

available_disks = black_host.configManager.datastoreSystem.QueryAvailableDisksForVmfs
device = available_disks[0]
#puts available_disks.inspect
options = black_host.configManager.datastoreSystem.QueryVmfsDatastoreCreateOptions(:devicePath => device.devicePath)
#puts options.pretty_inspect

puts "Partitioning new device"
# create partitions
hostDiskPartitionInfo = black_host.configManager.storageSystem.ComputeDiskPartitionInfo(
  :devicePath => device.devicePath,
  :layout => options[0].info.layout,
  :partitionFormat => "gpt")
black_host.configManager.storageSystem.UpdateDiskPartitions(:devicePath => device.devicePath, :spec => hostDiskPartitionInfo.spec)

puts "Creating datastore on new device"
options[0].spec.vmfs.volumeName = "local-black-ssd-raid-test"
black_host.configManager.datastoreSystem.CreateVmfsDatastore(:spec => options[0].spec)