public final class JniLoadProbe {
    public static void main(String[] args) {
        System.load(args[0]);
        System.out.println("JNI_LOADED");
    }
}
