/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
//#include "dataStructures/interfaces/Hashmap.nc"	// do I need this?
//#include "dataStructures/modules/HashmapC.nc"	// do I need this?

/*




What Protocol.h specifies:
PROTOCOL_PING = 0,
PROTOCOL_PINGREPLY = 1,
PROTOCOL_LINKEDLIST = 2,
PROTOCOL_NAME = 3,
PROTOCOL_TCP= 4,
PROTOCOL_DV = 5,
PROTOCOL_CMD = 99

What I specify:
protocol == 6 : Neighbor discovery packet

*/

module Node{
   uses interface Boot;
   uses interface SplitControl as AMControl;
   uses interface Receive;
   uses interface Random;
   uses interface SimpleSend as Sender;
   uses interface Timer<TMilli> as periodicTimer;//, randomTimer;	// Interface that was wired in NodeC.nc
   uses interface Timer<TMilli> as randomTimer;
   uses interface CommandHandler;



}


/*linkState structure
 --------  node1 node2 node3 node4 node5
 node1     0     1     1     0     1
 node2     1     0     0     0     1
 node3     ...   ...   ...
 */


implementation{	// each node's private variables must be declared here, (or it will only be declared once for all nodes, so they all share the same variable)
   pack sendPackage;


   // Holds current nodes understanding of entire network topology
   typedef struct routingTable
   {
     uint16_t neighborArray[50][50];
     uint16_t numNodes;
   } routing;


   // Holds current nodes neighbors
   typedef struct
   {
     uint16_t neighborArray[2][50];
     uint16_t numNodes;
   } neighborTable;




   // Used in neighbor discovery
   uint16_t neighbors [50];
   uint16_t top = 0;	// length of elements in neighbors. How many neighbors are in neighbors. index to add next element in neighbors

   // Used to keep track of previous packages sent, so as to not send them again
   //uint16_t prevTop = 0;	// previous top (when top is reset to 0, previous top will not be
   uint32_t sentPacks [50];	// stores a packet's ((seq<<16) | src)) taken of last 50 previous packets sent. This will help recognize if a packet has already been sent before, so not to send it again. First 16 bits are the packet's seq. Last 16 bits are packet's src
   uint16_t packsSent = 0;	// counts number of packets sent by this node. Is incremented when a new pack is sent. (packsSent % 50) is used as the index of sentPacks to write the newly packet to
   uint16_t mySeqNum = 0;	// counts number of packets created by this node (to keep track of duplicate packets). Is incremented when a new packet is created (with makePack)

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    void sendNeighborDiscoverPack() {
		char text [] = "hi";	// length is 2 (3 including null char byte '\0' at end)

		//reset the list to empty every time neighbor discovery is called, then re-add them to list when they respond
		top = 0;
	   dbg(NEIGHBOR_CHANNEL, "Discovering Neighbors. Sending packet: ");
	   makePack(&sendPackage, TOS_NODE_ID, TOS_NODE_ID, 1, 6, mySeqNum, text, PACKET_MAX_PAYLOAD_SIZE);
	   logPack(&sendPackage);
	   call Sender.send(sendPackage, AM_BROADCAST_ADDR);
	   sentPacks[packsSent%50] = (((sendPackage.seq) << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
	   packsSent++;
	   mySeqNum++;
	   // The recieve function will now make a list of everyone who responded to this packet (who forwards it back with TTL=0).
	   // Maybe the neighbors can just send it only back to the source instead of to AM_BROADCAST_ADDR to all?
   }

   void printNeighbors () {
	   int i;
	   dbg (NEIGHBOR_CHANNEL, "My %hhu neighbor(s) are:\n", top);

	   for (i = 0; i < top; i++) {
		   dbg (NEIGHBOR_CHANNEL, "%hhu\n", neighbors[i]);
	   }
   }

   void reply (uint16_t to) {
	   char text [] = "got it!\n";

	   makePack(&sendPackage, TOS_NODE_ID, to, 21, PROTOCOL_PINGREPLY, mySeqNum, text, PACKET_MAX_PAYLOAD_SIZE);
	   dbg(GENERAL_CHANNEL, "Sending reply to %hhu", to);
	   logPack(&sendPackage);
	   call Sender.send(sendPackage, AM_BROADCAST_ADDR);
	   sentPacks[packsSent%50] = ((sendPackage.seq << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
	   packsSent++;
	   mySeqNum++;

   }

   event void Boot.booted(){
      call AMControl.start();
	  call periodicTimer.startPeriodic(200000);
	  //call periodicTimer.fired();
	  //sendNeighborDiscoverPack();
	  call randomTimer.startOneShot((call Random.rand32())%200);	// immediately discover neighbors after random time

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void periodicTimer.fired() {
	   //printNeighbors ();
	   call randomTimer.startOneShot((call Random.rand32())%200);
   }

   event void randomTimer.fired() {
	   sendNeighborDiscoverPack();
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         //Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
	  int i;
	  uint32_t key;
      //dbg(GENERAL_CHANNEL, "\nPacket Received: ");


      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
		 //logPack (myMsg);		// just prints out package's info & payload
		 if (myMsg->dest == TOS_NODE_ID) {

			 // Make hashmap record packages recieved


			 //char text [] = "hi";	//"All neighbors, please reply";	// length is 27 (28 including null char byte '\0' at end)	// Network Discovery message
			 if (myMsg->TTL == 0 && myMsg->protocol == 6 && myMsg->src != TOS_NODE_ID/*&& strncmp(text, payload, 2) == 0*/) {	// Should this also check if a network discovery packet has been sent recently???

				 // record the neighbor (this packet's sender)
				 neighbors [top] = myMsg->src;
				 top++;
				 dbg (NEIGHBOR_CHANNEL, "Recieved my own network discovery packet from node %hhu. I now have %hhu neighbors\n", myMsg->src, top);

				 return msg;
			 } else {

				 if (myMsg->protocol == PROTOCOL_PINGREPLY) {
					 dbg (GENERAL_CHANNEL, "Recieved a reply to my message!\n");
					 logPack (myMsg);
					 return msg;
				 }

				 dbg (GENERAL_CHANNEL, "The message is for me!\n");
				 logPack (myMsg);
				 // send reply
				 reply(myMsg->src);


			 }

		 } else if (myMsg->TTL > 0 && myMsg->src != TOS_NODE_ID) {	// should also check that this packet wasn't already forwarded by this node (store a list of packets already forwarded in a hashmap or a list)
			 myMsg->TTL --;	// will decrementing TTL and incrementing seq this way work? Or do I have to make a new packet?
			 //myMsg->seq ++;

			 // check if it's another node's network discovery packet
			 if (myMsg->src == myMsg->dest) {	// if source == destination, then it's a network discovery packet
				 dbg (NEIGHBOR_CHANNEL, "Recieved someone else's neighbor discovery packet. Sending it back to them\n");
				 myMsg->src = TOS_NODE_ID;	// set souce of network discovery packets to current node
				 call Sender.send(*myMsg, myMsg->dest);	// send it back to the sender
				 sentPacks[packsSent%50] = ((myMsg->seq << 16) | myMsg->src);	// keep track of all packs send so as not to send them twice
				 packsSent++;
				 return msg;
			 }

			 // check if packet has been sent by me before (in last 50 messages)

			 key = ((myMsg->seq << 16) | myMsg->src);	// lookup sentPacks by whether the pack's seq (number of packs made by the sender at the time) and src (the sender) match a previous packet sent
			 for (i = 0; i < 50; i++) {
				 if (key == sentPacks[i]) {
					 break;
				 }
			 }
			 if (i != 50) {	// if i == 50, then that means it went through the entire array, and didn't find any match. So the packet must not have been sent before in last 50 forwards
				 dbg(GENERAL_CHANNEL, "Recieved a packet I already sent. Dropping packet.\n");
				 return msg;
			 }

			 dbg (GENERAL_CHANNEL, "It's not for me. forwarding it on\n");
			 //**************************************************************8
			 // Should this store an array of last "top" (number of neighbors) amount of packets stored, to tell when one of them was sent back to previous node again????? That way packets won't go back and forth?????
			 call Sender.send(*myMsg, AM_BROADCAST_ADDR);
			 sentPacks[packsSent%50] = ((myMsg->seq << 16) | myMsg->src);	// keep track of all packs send so as not to send them twice
			 packsSent++;
		 } else if (myMsg->TTL <= 0) {
			 dbg (GENERAL_CHANNEL, "I recieved a packet with no more time to live. Dropping packet\n");
		 } else if (myMsg->src == TOS_NODE_ID) {
			 dbg (GENERAL_CHANNEL, "I recieved my own packet\n");
		 }

         return msg;
      }
      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);



      return msg;
   }


   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "\nPINGING:\t\t");
      makePack(&sendPackage, TOS_NODE_ID, destination, 21, PROTOCOL_PING, mySeqNum, payload, PACKET_MAX_PAYLOAD_SIZE);
	  logPack(&sendPackage);	// just prints out package's info & payload
	  //dbg(GENERAL_CHANNEL, "Pinging payload ", payload, " from ", TOS_NODE_ID, " to ", destination, "\n");
      dbg(GENERAL_CHANNEL, "\n");
	  /*
	  if (destination == TOS_NODE_ID) {
		  dbg(GENERAL_CHANNEL, "Node " + str(TOS_NODE_ID) + "recieved a ping\n")
	  } else {
		  while (Time to live > 0) {
			call Sender.send(sendPackage, AM_BROADCAST_ADDR);
			sentPacks[packsSent%50] = ((sendPackage.seq << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
			packsSent++;
		  }

	  }
	  */
	  //call Sender.send(sendPackage, destination);
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
	  mySeqNum++;
	  packsSent++;
   }

   event void CommandHandler.printNeighbors(){
	   printNeighbors ();
   }

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }
}
