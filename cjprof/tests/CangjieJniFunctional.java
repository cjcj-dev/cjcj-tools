// Copyright (c) Huawei Technologies Co., Ltd. 2026. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
import com.cjprof.jni.Cjprof;
import com.cjprof.jni.model.*;
import java.nio.file.*;
import java.util.*;

public class CangjieJniFunctional {
    static int checks;
    static void check(boolean condition, String message) {
        checks++; System.out.println("ASSERT " + checks + " " + message + " " + condition);
        if (!condition) throw new AssertionError(message);
    }
    static Map<Long,ConstructorNode> constructors(long sid) {
        Map<Long,ConstructorNode> out = new HashMap<>();
        for (ConstructorNode n : Cjprof.getConstructorNodesBySnapshotID(sid)) out.put(n.getId(),n);
        return out;
    }
    static int javaExceptions(int divisor) {
        try { return 123/divisor; }
        catch (ArithmeticException arithmetic) {
            try { Object value=null; return value.hashCode(); }
            catch (NullPointerException nullValue) { return 1; }
        }
    }
    public static void main(String[] args) throws Exception {
        Cjprof.initialize(); Cjprof.initialize();
        int handled=0; for(int i=0;i<20000;i++) handled+=javaExceptions(0);
        check(handled==20000,"Java exceptions remain handled after runtime startup");
        check(Cjprof.queryAllHeapSnapshot().isEmpty(), "initial registry empty");
        String root = args[0]; String basePath = args[1]; String targetPath = args[2];
        check(Cjprof.parseHeapSnapshotFiles(Collections.singletonList(basePath)) && Cjprof.queryAllHeapSnapshot().size()==1,"single original heap registered");
        check(Cjprof.parseHeapSnapshotFiles(Arrays.asList(basePath,targetPath)), "parse original two heap fixtures");
        long base=Cjprof.getSnapshotIDByFilePath(basePath), target=Cjprof.getSnapshotIDByFilePath(targetPath);
        check(base!=0 && target!=0 && base!=target,"opaque path IDs distinct");
        check(Cjprof.parseHeapSnapshotFiles(Collections.singletonList(basePath)) && Cjprof.queryAllHeapSnapshot().size()==2,"repeat parse deduplicates");
        for(HeapSnapshot s:Cjprof.queryAllHeapSnapshot()) {
            check(s.getFileSize()==Files.size(Path.of(s.getFilePath())),"snapshot file size/path");
        }
        Map<Long,ConstructorNode> b=constructors(base), t=constructors(target);
        check(!b.isEmpty() && !t.isEmpty(),"constructor query real objects");
        boolean kids=false,refs=false,paths=false;
        for(ConstructorNode con:b.values()) {
            ConstructorNode page=Cjprof.expandConstructorNode(base,con.getId(),0,con.getChildrenCount());
            check(page.getChildren().size()==con.getChildrenCount(),"constructor complete expansion");
            check(page.getNodeIndex()==con.getNodeIndex(),"stable UI handle");
            for(InstanceNode n:page.getChildren()) {
                InstanceNode full=Cjprof.expandInstanceNode(base,n.getId(),0,100000);
                kids|=!full.getChildren().isEmpty();refs|=!full.getRetainerNodes().isEmpty();
                InstanceNode child=Cjprof.expandDetailNode(base,n.getId(),false,0,100000);
                InstanceNode ref=Cjprof.expandDetailNode(base,n.getId(),true,0,100000);
                check(child.getChildren().size()==full.getChildren().size() && child.getRetainerNodes().isEmpty(),"detail children only");
                check(ref.getRetainerNodes().size()==full.getRetainerNodes().size() && ref.getChildren().isEmpty(),"detail retainers only");
                List<List<InstanceNode>> all=Cjprof.getNodeRootpaths(base,n.getId(),-1);
                if(all.size()>=2) {check(Cjprof.getNodeRootpaths(base,n.getId(),1).size()==1,"root paths truncate");paths=true;}
            }
        }
        check(kids&&refs,"outgoing and incoming expansion executed");
        check(paths,"multiple root paths executed");
        Set<Byte> types=new HashSet<>(Arrays.asList((byte)1,(byte)2,(byte)255));
        check(Cjprof.getRootNodesBySnapshotID(base,Collections.emptySet()).isEmpty(),"empty root filter");
        List<ConstructorNode> roots=Cjprof.getRootNodesBySnapshotID(base,types);
        check(!roots.isEmpty() && roots.stream().anyMatch(n->!n.getChildren().isEmpty()),"root filter positive");
        List<ThreadInfo> threads=Cjprof.getThreadInfos(base);
        check(!threads.isEmpty() && threads.stream().anyMatch(n->!n.getFrames().isEmpty()),"thread frames real fixture");
        check(threads.stream().flatMap(n->n.getFrames().stream()).anyMatch(n->!n.getLocals().isEmpty()),"thread locals consumed");
        int allCount=Cjprof.querySnapshotCountOfResults("",true,base);
        check(allCount>0 && Cjprof.querySnapshotCountOfResults("ZZZ_NOMATCH_ZZZ",true,base)==0,"keyword positive/negative");
        check(Cjprof.querySnapshotNodeByIndex("",true,base,5,0).getClassName().isEmpty(),"zero result index");
        for(int i=1;i<=allCount;i++) check(!Cjprof.querySnapshotNodeByIndex("",true,base,1,i).getChildren().isEmpty(),"snapshot result pagination");
        long anInstance=Cjprof.expandConstructorNode(base,b.values().iterator().next().getId(),0,1).getChildren().get(0).getId();
        InstanceDiffNode sameInstance=Cjprof.expandInstanceDiffNode(base,base,anInstance,0,100);
        check(!sameInstance.getClassName().isEmpty() && sameInstance.getAddedCount()==0 && sameInstance.getRemovedCount()==0,"unchanged class diff cache miss");
        check(Cjprof.getConstructorNodesBySnapshotID(0).isEmpty() && Cjprof.getThreadInfos(0).isEmpty(),"invalid snapshot empty collections");
        check(Cjprof.expandConstructorNode(0,0,0,1).getClassName().isEmpty() && Cjprof.expandInstanceNode(0,0,0,1).getClassName().isEmpty(),"invalid snapshot default models");
        check(Cjprof.querySnapshotCountOfResults("",true,0)==0 && Cjprof.querySnapshotNodeByIndex("",true,0,1,1).getClassName().isEmpty(),"invalid snapshot empty search");
        List<ConstructorDiffNode> diffs=Cjprof.querySnapshotComparison(base,target);
        check(!diffs.isEmpty(),"comparison positive");
        check(Cjprof.querySnapshotComparison(base,base).isEmpty(),"same snapshot comparison negative");
        boolean both=false,baseOnly=false,targetOnly=false;
        for(ConstructorDiffNode diff:diffs) {
            both|=b.containsKey(diff.getId())&&t.containsKey(diff.getId());
            baseOnly|=b.containsKey(diff.getId())&&!t.containsKey(diff.getId());
            targetOnly|=!b.containsKey(diff.getId())&&t.containsKey(diff.getId());
            ConstructorDiffNode page=Cjprof.expandConstructorDiffNode(base,target,diff.getId(),0,100000);
            check(page.getChildren().size()==page.getChildAddedStates().size(),"diff states align instances");
            check(page.getCountDelta()==(long)page.getAddedCount()-page.getRemovedCount(),"diff signed count delta");
            for(InstanceNode n:page.getChildren()) {
                InstanceDiffNode first=Cjprof.expandInstanceDiffNode(base,target,n.getId(),0,100000);
                InstanceDiffNode second=Cjprof.expandInstanceDiffNode(base,target,n.getId(),0,100000);
                check(first.getClassName().equals(second.getClassName()) && first.isAdded()==second.isAdded(),"diff first/repeat cache");
                check(Cjprof.expandDetailDiffNode(base,target,n.getId(),true,0,100000).getChildren().isEmpty(),"diff reference branch");
                check(Cjprof.expandDetailDiffNode(base,target,n.getId(),false,0,100000).getRetainerNodes().isEmpty(),"diff children branch");
            }
        }
        check(both&&baseOnly&&targetOnly,"all three constructor diff presence branches");
        check(!Cjprof.getRootDiffNodesBySnapshotID(base,target,types).isEmpty(),"root diff positive");
        int diffCount=Cjprof.queryComparisonCountOfResults("",true,base,target);
        check(diffCount>0 && Cjprof.queryComparisonCountOfResults("ZZZ_NOMATCH_ZZZ",true,base,target)==0,"comparison keyword positive/negative");
        check(Cjprof.queryComparisonNodeByIndex("",true,base,target,5,0).getClassName().isEmpty(),"comparison zero index");
        for(int i=1;i<=diffCount;i++) check(!Cjprof.queryComparisonNodeByIndex("",true,base,target,1,i).getChildren().isEmpty(),"comparison result pagination");
        String diamond=root+"/diamond-2-8.data";
        check(Cjprof.parseHeapSnapshotFiles(Collections.singletonList(diamond)),"parse Unicode diamond");
        long sid=Cjprof.getSnapshotIDByFilePath(diamond);
        ConstructorNode cls=Cjprof.getConstructorNodesBySnapshotID(sid).get(0);
        check(cls.getClassName().equals("包::类"),"JNI Unicode round trip");
        InstanceNode entry=Cjprof.expandInstanceNode(sid,1,0,100);
        check(entry.getChildren().size()==2 && entry.getShallowSize()==8,"diamond graph/shallow control");
        check(entry.getRetainedSize()==32,"JNI retained diamond target");
        check(Cjprof.expandInstanceNode(sid,4,0,100).getRetainerNodes().size()==2,"JNI multi reference dedup");
        check(Cjprof.querySnapshotCountOfResults("\u0000",true,sid)==0,"embedded NUL search preserved");
        check(!Cjprof.parseHeapSnapshotFiles(Collections.singletonList(root+"/missing.data")),"missing file rejected");
        check(!Cjprof.parseHeapSnapshotFiles(Collections.singletonList(root+"/truncated-21.data")),"malformed file rejected");
        List<Long> ids=new ArrayList<>();for(HeapSnapshot s:Cjprof.queryAllHeapSnapshot())ids.add(s.getId());
        Cjprof.cleanHeapSnapshotFiles(ids);check(Cjprof.queryAllHeapSnapshot().isEmpty(),"cleanup clears registry and comparison cache");
        check(Cjprof.parseHeapSnapshotFiles(Collections.singletonList(basePath)),"reload after cleanup");
        Cjprof.cleanHeapSnapshotFiles(Collections.singletonList(base));
        System.out.println("PASS JNI 21 methods / "+checks+" assertions");
    }
}
