import me.dilley.MineStat;

class Example
{
  public static void main(String[] args)
  {
    MineStat ms = new MineStat("fun.frag.land");
    //MineStat ms = new MineStat("fun.frag.land", 19132, 5, MineStat.Request.BEDROCK);
    System.out.println("Minecraft server status of " + ms.getAddress() + " on port " + ms.getPort() + ":");
    if(ms.isServerUp())
    {
      System.out.println("Server is online running version " + ms.getVersion() + " with " + ms.getCurrentPlayers() + " out of " + ms.getMaximumPlayers() + " players.");
      if(ms.getRequestType() == "Bedrock/Pocket Edition")
        System.out.println("Game mode: " + ms.getGameMode());
      System.out.println("Message of the day: " + ms.getMotd());
      System.out.println("Message of the day without formatting: " + ms.getStrippedMotd());
      System.out.println("Latency: " + ms.getLatency() + "ms");
      System.out.println("Connected using protocol: " + ms.getRequestType());
    }
    else
      System.out.println("Server is offline!");
  }
}
