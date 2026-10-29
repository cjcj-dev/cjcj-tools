// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
import com.cjprof.jni.Cjprof;
import com.cjprof.jni.model.*;
import java.util.*;

public class CangjieJniBoundaries {
    static int checks, failed;
    static void check(boolean value, String name) {
        checks++; if (!value) failed++;
        System.out.println("ASSERT " + checks + " " + name + " " + value);
    }
    static long u(int value) { return Integer.toUnsignedLong(value); }
    static void percent(double actual, long numerator, long denominator, String name) {
        check(Math.abs(actual-100.0*numerator/denominator)<1e-10,name);
    }
    public static void main(String[] args) {
        Cjprof.initialize();
        // Literal expectations from the original public uint32 model and explicit
        // UINT32_MAX saturation, including unsigned values crossing Java INT_MAX.
        String[] names={"low","signed","near","saturated","group","chain","base"};
        long[] totals={0x7ffffff8L,0x80000000L,0xfffffff8L,0xffffffffL,0xffffffffL,0xffffffffL,0x80000000L};
        long[] groupSizes={0x7ffffff8L,0x80000000L,0xfffffff8L,0x80000000L,0,0,0x80000000L};
        long[] retained={0x7ffffff8L,0x80000000L,0xfffffff8L,0x80000000L,0,0x80000000L,0x80000000L};
        long base=0,target=0;
        for(int i=0;i<names.length;i++) {
            String file=args[0]+"/"+names[i]+".data";
            check(Cjprof.parseHeapSnapshotFiles(Collections.singletonList(file)),names[i]+" parse real heap");
            long sid=Cjprof.getSnapshotIDByFilePath(file);
            if(names[i].equals("base"))base=sid;
            if(names[i].equals("group"))target=sid;
            List<ConstructorNode> nodes=Cjprof.getConstructorNodesBySnapshotID(sid);
            check(nodes.size()==(names[i].equals("saturated")?2:1),names[i]+" constructor count control");
            for(ConstructorNode n:nodes) {
                check(u(n.getTotalSize())==totals[i],names[i]+" constructor saturated total");
                check(u(n.getShallowSize())==groupSizes[i],names[i]+" constructor uint32 shallow accumulation");
                check(u(n.getRetainedSize())==retained[i],names[i]+" constructor uint32 retained accumulation");
                percent(n.getShallowSizePercent(),groupSizes[i],totals[i],names[i]+" constructor shallow percentage");
                percent(n.getRetainedSizePercent(),retained[i],totals[i],names[i]+" constructor retained percentage");
                ConstructorNode page=Cjprof.expandConstructorNode(sid,n.getId(),0,100);
                check(page.getChildren().size()==n.getChildrenCount(),names[i]+" real expansion control");
                for(InstanceNode child:page.getChildren()) {
                    InstanceNode instance=Cjprof.expandInstanceNode(sid,child.getId(),0,100);
                    long size=i<3?totals[i]:0x80000000L;
                    long keep=names[i].equals("chain")&&instance.getId()==0x1000?0:size;
                    check(u(instance.getTotalSize())==totals[i],names[i]+" instance saturated total");
                    check(u(instance.getShallowSize())==size,names[i]+" instance shallow bit pattern control");
                    check(u(instance.getRetainedSize())==keep,names[i]+" instance retained uint32 accumulation");
                    percent(instance.getShallowSizePercent(),size,totals[i],names[i]+" instance shallow percentage");
                    percent(instance.getRetainedSizePercent(),keep,totals[i],names[i]+" instance retained percentage");
                }
            }
        }
        List<ConstructorDiffNode> diffs=Cjprof.querySnapshotComparison(base,target);
        check(diffs.size()==1,"diff changed constructor control");
        for(ConstructorDiffNode d:diffs) {
            check(u(d.getBaseTotalSize())==0x80000000L,"diff base total boundary");
            check(u(d.getTargetTotalSize())==0xffffffffL,"diff target saturated total");
            check(u(d.getAddedSize())==0x80000000L&&u(d.getRemovedSize())==0,"diff cumulative uint32 sizes");
            check(d.getSizeDelta()==0x80000000L,"diff signed long delta from uint32 fields");
            ConstructorDiffNode page=Cjprof.expandConstructorDiffNode(base,target,d.getId(),0,100);
            check(u(page.getBaseTotalSize())==0x80000000L&&u(page.getTargetTotalSize())==0xffffffffL,"expanded diff totals");
        }
        System.out.println("JNI boundaries "+checks+" assertions; failed="+failed);
        if(failed>0)System.exit(1);
    }
}
