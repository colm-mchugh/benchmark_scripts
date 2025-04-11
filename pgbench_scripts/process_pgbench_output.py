#!/usr/bin/python3

import sys
import os
import argparse

from os.path import expanduser

def wrap_quotes(txt):
    return "'" + str(txt) + "'"

args_parser = argparse.ArgumentParser(
    prog='process_pgbench_output',
    description='Convert pgbench output to CSV formatted data'
)
args_parser.add_argument('--filename',action='store',required=True,help='File with pgbench output')
args_parser.add_argument('--maketable', help='create database table')

args=args_parser.parse_args()

input_file=str(args.filename)
run_label=input_file.split('.out')[0] 
lines = [l.strip() for l in open(input_file)]
pgbrs = []
pgbr = {}

for line in lines:
    if line.startswith('PGHOST'):
        pgbr['pghost'] = (line.split('=')[1]) 
        pgbr['cluster'] = pgbr['pghost'].split('.')[0]
        pgbr['label'] = run_label
    elif line.startswith('start time: '):
        pgbr['start_time'] = wrap_quotes(line.split('start time: ')[1])
    elif line.startswith('end time: '):
        pgbr['end_time'] = wrap_quotes(line.split('end time: ')[1])
        if 'tps' in pgbr.keys():
            pgbrs.append(pgbr)
        pgbr={}
    elif line.startswith('tps = '):
        pgbr['tps'] = line.split('tps = ')[1].split(' ')[0]
    elif line.startswith('latency average = '):
        latency_info = line.split('latency average = ')[1].split(' ')
        pgbr['latency_avg'] = latency_info[0]
        pgbr['latency_units'] = (latency_info[1])
    elif line.startswith('number of transactions actually processed: '):
        pgbr['transactions'] = line.split('number of transactions actually processed:')[1]
    elif line.startswith('duration: '):
        pgbr['duration'] = line.split('duration: ')[1].split(' ')[0]
    elif line.startswith('number of threads: '):
        pgbr['threads'] = line.split('number of threads: ')[1] 
    elif line.startswith('number of clients: '):
        pgbr['clients'] = line.split('number of clients: ')[1] 
    elif line.startswith('pgbench: fatal:'):
        print("pgbench run encountered an error: %s\n", line)

output=[]
output_order=['label', 'cluster', 'clients', 'threads', 'duration', 'transactions', 'tps', 'latency_avg', 'latency_units', 'start_time', 'end_time', 'pghost']

for pgbr in pgbrs:
    output_line=', '.join(pgbr[kval] for kval in output_order)
    output.append(output_line)

output_dir = expanduser("~") + "/"

if args.maketable:
    ddlf = 'create_pgbench.sql'
    ddlf_path = output_dir + '/' + ddlf
    fsql = open(ddlf_path, 'w')
    fsql.write("DROP TABLE IF EXISTS pgbench_results;\n")
    fsql.write("CREATE TABLE pgbench_results(\n")
    fsql.write("    label text, cluster text, clients int, threads int, \n")
    fsql.write("    duration int, transactions bigint, tps float, latency_avg float, \n")
    fsql.write("    latency_units varchar(12), start_time timestamp, end_time timestamp,\n")
    fsql.write("    pghost text, run_id serial primary key);\n")
    fsql.close()
    create_cmd = 'psql -f ' + ddlf_path
    os.system(create_cmd)
    os.system("rm -rf " + ddlf_path)

# load data into pgbench_results table
dmlf = 'load_pgbench.sql'
dmlf_path = output_dir + '/' + dmlf
f = open(dmlf_path, 'w')
f.write("COPY pgbench_results(")
f.write(','.join(col_name for col_name in output_order))
f.write(")   FROM stdin delimiter ',' csv;\n")
for pgbr in pgbrs:
    csv_formatted_line=','.join(pgbr[kval] for kval in output_order)
    f.write(csv_formatted_line + '\n')
f.close()
load_cmd = 'psql -f ' + dmlf_path
os.system(load_cmd)
os.system("rm -rf "+ dmlf_path)

