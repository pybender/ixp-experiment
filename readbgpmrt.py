#!/usr/bin/env python

from optparse import OptionParser
from pybgpdump import BGPDump
import dpkt
import time
import socket
import struct
from os import listdir
from os.path import isfile, join, exists
from itertools import izip_longest

def main():
    parser = OptionParser()
    parser.add_option('-f', '--file', dest='filename',
                      help='read input from FILE', metavar='FILE')
    (options, args) = parser.parse_args()

    messages = 0
    announced = 0
    withdrawn = 0

    buf = struct.pack("!BBBBB", 24, 20, 0, 0, 0)
    observed_prefix = dpkt.bgp.RouteIPV4(buf)

    LOG_DIR = "/home/trungth/git/ixp-lab/logs/tlong"
    data = []
    testids = []
    for n in range(30, 31, 10):
        sd = join(LOG_DIR, str(n))
        if not exists(sd):
            continue
        # Number of member ASes
        num_member_ases = n
        ar = []
        testids.append("nAS#%d" % n)
        #print "Run#(%d)\tAST1\t\tRS\t\tAS_AVG\t\tCONVG(s)" % n
        for d in listdir(sd):
            p = join(sd, d)
            (ts1, avg, cvg) = correlate(p, num_member_ases, observed_prefix)
            if ts1 == 0:
                continue
            #print "%s\t%d\t%d\t%d" % ( d, ts1, avg, cvg )
            ar.append(cvg)
        data.append(ar)
    #print data
    #for col in izip_longest(*data, fillvalue='  '):
    #    print col
    print '\t'.join([x for x in testids])
    print '\n'.join(['\t'.join([str(x[i]) if len(x) > i else '' for x in data]) for i in range(len(max(data)))])


def correlate(d, num_ases, observed_prefix):
    ts = []
    # Read timestamp of the announcement sent by AST1
    #ts.append(get_update_timestamp(join(d, "as-t1-updates.dump"), observed_prefix))
    ts.append(get_update_timestamp(join(d, "rs-updates.dump"), 0, observed_prefix))
    #ts.append(get_update_timestamp(join(d, "as1-updates.dump"), 1, observed_prefix))

    for i in range(1, num_ases):
        ts.append( get_update_timestamp(
                    join(d, "as%d-updates.dump" % i), 1,
                    observed_prefix) )
    ma = max(ts) # Max TS
    ts1 = ts[0] # TS of UPDATE at AST1
    #ts2 = ts[1] # TS of UPDATE at RS
    cvg = []
    for i in ts[1:]:
        cvg.append( i - ts1 )
    avg = sum(cvg) / float(len(cvg)) # Average TS of UPDATE at member ASes)
    #avg = sum(ts[1:])/float(len(ts[1:])) - ts1
    print (ts1, ts[1:])
    return (ts1, ma - ts1, avg)
    #return (0, 0, 0, 0)

# utype = 1: announce, utype=0: withdraw
def get_update_timestamp(fname, utype, observed_prefix):
    f = None
    try:
        f = open(fname, 'rb')
    except:
        f = None

    if (f != None):
        while True:
            s = f.read(dpkt.mrt.MRTHeader.__hdr_len__)
            if len(s) < dpkt.mrt.MRTHeader.__hdr_len__:
                f.close()
                break
            mrt_h = dpkt.mrt.MRTHeader(s)
            s = f.read(mrt_h.len)
            if len(s) < mrt_h.len:
                f.close()
                break
            if mrt_h.type != dpkt.mrt.BGP4MP:
                continue
            if mrt_h.subtype == dpkt.mrt.BGP4MP_STATE_CHANGE:
                continue
            elif mrt_h.subtype == dpkt.mrt.BGP4MP_MESSAGE:
                bgp_h = dpkt.mrt.BGP4MPMessage(s)
            elif mrt_h.subtype == dpkt.mrt.BGP4MP_MESSAGE_32BIT_AS:
                bgp_h = dpkt.mrt.BGP4MPMessage_32(s)
                if bgp_h.family != dpkt.mrt.AFI_IPv4:
                   continue
                # Construct BGP packet
                bgp_m = dpkt.bgp.BGP(bgp_h.data)
                if bgp_m.type == dpkt.bgp.OPEN:
                    continue
                elif bgp_m.type == dpkt.bgp.UPDATE:
                    if utype:
                        routes = bgp_m.update.announced
                    else:
                        routes = bgp_m.update.withdrawn

                    for r in routes:
                        if r == observed_prefix:
                            if utype:
                                #print mrt_h.ts, bgp_h.src_as, bgp_h.dst_as
                                for at in bgp_m.update.attributes:
                                    if at.type == dpkt.bgp.AS_PATH \
                                            and at.as_path.segments[0].len > 1:
                                        #print fname, mrt_h.ts
                                        #print mrt_h.ts, bgp_h.src_as, bgp_h.dst_as
                                        #print mrt_h.ts, bgp_m.update.attributes
                                        return mrt_h.ts
                            else:
                                #print mrt_h.ts, bgp_h.src_as, bgp_h.dst_as
                                #print bgp_m.update.attributes
                                return mrt_h.ts

                elif bgp_m.type == dpkt.bgp.NOTIFICATION:
                    continue
                elif bgp_m.type == dpkt.bgp.KEEPALIVE:
                    continue
                elif bgp_m.type == dpkt.bgp.ROUTE_REFRESH:
                    continue
    return 0
if __name__ == '__main__':
    main()
