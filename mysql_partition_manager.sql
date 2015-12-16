# Copyright 2015 Yahoo Inc. Licensed under the terms of Apache License 2.0. Please see the LICENSE file for terms.

drop procedure if exists partition_manager;

delimiter ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `partition_manager`()
begin

declare done tinyint unsigned;
declare p_table,p_column varchar(64) character set latin1;
declare p_granularity,p_increment,p_retain,p_buffer int unsigned;
declare run_timestamp,current_val int unsigned;
declare partition_list text character set latin1;

declare cur_table_list cursor for select s.table,s.column,s.granularity,s.increment,s.retain,s.buffer from partition_manager_settings s;

DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

set session group_concat_max_len=65535;

set run_timestamp=unix_timestamp();

open cur_table_list;
manage_partitions_loop: loop
	set done=0;
	fetch cur_table_list into p_table,p_column,p_granularity,p_increment,p_retain,p_buffer;
	if done=1 then
		leave manage_partitions_loop;
	end if;


	# verification

	select if(t.create_options like '%partitioned%',null,ceil(unix_timestamp()/ifnull(p_increment,1))*ifnull(p_increment,1))
		from information_schema.tables t
		where t.table_schema=DATABASE()
		and t.table_name=p_table
		into current_val;

	if current_val is not null then
		set partition_list:='';
		if p_retain is not null then
			while current_val>run_timestamp-p_retain do
				set current_val:=current_val-p_increment;
				set partition_list:=concat('partition p_',floor(current_val/p_granularity),' values less than (',floor(current_val/p_granularity),'),',partition_list);
			end while;
		end if;
		
		SET @sql:=CONCAT('alter table ',p_table,' partition by range (',p_column,') (partition p_START values less than (0),',partition_list,'partition p_END values less than MAXVALUE)');
		PREPARE stmt FROM @sql;
		EXECUTE stmt;
		deallocate prepare stmt;
	end if;


	# add

	if p_buffer is not null then
		select ifnull(max(p.partition_description)*p_granularity,floor(unix_timestamp()/p_increment)*p_increment)
			from information_schema.partitions p
			where p.table_schema=DATABASE()
			and p.table_name=p_table
			and p.partition_description>0
			into current_val;
		
		set partition_list:='';
		while current_val<run_timestamp+p_buffer do
			set current_val:=current_val+p_increment;
			set partition_list:=concat(partition_list, 'partition p_',floor(current_val/p_granularity),' values less than (',floor(current_val/p_granularity),'),');
		end while;
		
		if partition_list>'' then
			SET @sql:=CONCAT('ALTER TABLE ',p_table,' REORGANIZE PARTITION p_END into (',partition_list,'partition p_END values less than maxvalue)');
			PREPARE stmt FROM @sql;
			EXECUTE stmt;
			deallocate prepare stmt;
		end if;
	end if;
	

	# purge
	
	if p_retain is not null then
		set partition_list='';
		select group_concat(p.partition_name separator ',')
			from information_schema.partitions p
			where p.table_schema=DATABASE()
			and p.table_name=p_table
			and p.partition_description<=floor((run_timestamp-p_retain)/p_granularity)
			and p.partition_description>0
			into partition_list;
		if partition_list>'' then
			SET @sql:=CONCAT('ALTER TABLE ',p_table,' DROP PARTITION ',partition_list);
			PREPARE stmt FROM @sql;
			EXECUTE stmt;
			deallocate prepare stmt;
		end if;
	end if;
	
end loop;
close cur_table_list;


# confirm schedule for next run

call schedule_partition_manager(); /* 5.6.29+/5.7.11+ only - mysql bug 77288 */cal

END;;
DELIMITER ;


drop event if exists run_partition_manager;

DELIMITER ;;
CREATE DEFINER=`root`@`localhost` EVENT `run_partition_manager` ON SCHEDULE EVERY 86400 SECOND STARTS '2000-01-01 00:00:00' ON COMPLETION PRESERVE ENABLE DO
BEGIN
IF @@global.read_only=0 THEN
	CALL partition_manager();
END IF;
END;;
DELIMITER ;

drop procedure if exists schedule_partition_manager;

DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `schedule_partition_manager`()
begin

declare min_increment int unsigned;

set min_increment=null;
select min(s.increment)
from partition_manager_settings s
into min_increment;

if min_increment is not null then
	ALTER DEFINER='root'@'localhost' EVENT run_partition_manager ON SCHEDULE EVERY min_increment SECOND STARTS '2000-01-01 00:00:00' ENABLE;
end if;

end;;
delimiter ;


drop procedure if exists install_partition_manager;

DELIMITER ;;
CREATE DEFINER=`root`@`localhost` PROCEDURE `install_partition_manager`()
begin

drop table if exists partition_manager_settings_new;

CREATE TABLE `partition_manager_settings_new` (
  `table` varchar(64) NOT NULL COMMENT 'table name',
  `column` varchar(64) NOT NULL COMMENT 'numeric column with time info',
  `granularity` int(10) unsigned NOT NULL COMMENT 'granularity of column, i.e. 1=seconds, 60=minutes...',
  `increment` int(10) unsigned NOT NULL COMMENT 'seconds per individual partition',
  `retain` int(10) unsigned NULL COMMENT 'seconds of data to retain, null for infinite',
  `buffer` int(10) unsigned NULL COMMENT 'seconds of empty future partitions to create',
  PRIMARY KEY (`table`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 ROW_FORMAT=Dynamic;

set @sql=null;
select concat('insert into partition_manager_settings_new (',group_concat(concat('`',cn.column_name,'`')),') select ',group_concat(concat('so.',cn.column_name)),' from partition_manager_settings so')
from information_schema.columns cn
join information_schema.columns co on co.table_schema=cn.table_schema and co.column_name=cn.column_name
where cn.table_name='partition_manager_settings_new'
and co.table_name='partition_manager_settings'
into @sql;

if @sql is not null then
	PREPARE stmt FROM @sql;
	EXECUTE stmt;
	deallocate prepare stmt;
end if;

drop table if exists partition_manager_settings;

rename table partition_manager_settings_new to partition_manager_settings;

call schedule_partition_manager(); /* 5.6.29+/5.7.11+ only - mysql bug 77288 */

end;;
delimiter ;


call install_partition_manager;

drop procedure if exists install_partition_manager;
