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
PROTOCOL_LINKEDSTATE = 2,
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
   uses interface Queue<uint16_t> as q;

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
   //typedef struct routingTable
   //{
     uint8_t routingTableNeighborArray[PACKET_MAX_PAYLOAD_SIZE * 8][PACKET_MAX_PAYLOAD_SIZE * 8];
     uint16_t routingTableNumNodes;
   //} routing;


   //typedef struct forwardingTable
   //{
     uint16_t forwardingTableTo[50];
     uint16_t forwardingTableNext[50];

     // max index number for both arrays
     // to[0] | next[0]
     // to[1] | next[1]

     uint16_t forwardingTableNumNodes;

   //} forwarding;




   // Holds current nodes neighbors, each bit corresponds to a node, 1/0 bit if node is a neighbors
   // Assume max number of nodes is 50, so 64 bits or 8 bytes can be sent in the payload

   // Holds 64 bits or up to 64 nodes
   //uint16_t neighborBits[4];




   // Used in neighbor discovery
   uint16_t neighbors [50];
   uint16_t top = 0;	// length of elements in neighbors. How many neighbors are in neighbors. index to add next element in neighbors

   // Used to keep track of previous packages sent, so as to not send them again
   //uint16_t prevTop = 0;	// previous top (when top is reset to 0, previous top will not be
   uint32_t sentPacks [50];	// stores a packet's ((seq<<16) | src)) taken of last 50 previous packets sent. This will help recognize if a packet has already been sent before, so not to send it again. First 16 bits are the packet's seq. Last 16 bits are packet's src
   uint16_t packsSent = 0;	// counts number of packets sent by this node. Is incremented when a new pack is sent. (packsSent % 50) is used as the index of sentPacks to write the newly packet to
   uint16_t mySeqNum = 0;	// counts number of packets created by this node (to keep track of duplicate packets). Is incremented when a new packet is created (with makePack). Is used as the sequence number when making a new pack

   // Prototypes

	// Sets the (shiftFromFront)th bit from left, in array "data", to valToSetTo (0 or 1)
	int setBit (uint8_t * data, int shiftFromFront, uint8_t valToSetTo) {
		uint8_t ind;
		uint8_t offset;
		uint8_t mask;

		ind = shiftFromFront / 8;	// index of byte in data[] array
		offset = shiftFromFront % 8;; // index of bit in byte to set
		mask = (0b10000000) >> offset;

		//dbg (GENERAL_CHANNEL, "setBit was called\n");
		if (!(valToSetTo == 0 || valToSetTo == 1)) {
			printf ("setBit error: setBit can only set a bit to 0 or 1\n");
			return 0;
		}

		if (valToSetTo == 1) {
			// sets the bit to 1
			data[ind] = data[ind]| mask;	// The operation (data[ind] & (~mask)) will clear the "offset"th bit in "ind"th byte, setting it to 0. Then  (_ | mask) sets it to 0 or 1, depending on what the mask bit is
		} else {
			// sets the bit to 0
			data[ind] = data[ind] & (~mask);
		}
		// returns 1 if it set it successfully, 0 otherwise.
		return 1;
	}

	// Sets the (shiftFromFront)th bit from left, in array "data", to valToSetTo (0 or 1)
	int getBit (uint8_t * data, int shiftFromFront) {
		uint8_t ind;
		uint8_t offset;
		uint8_t mask;
		uint8_t bit;

		ind = shiftFromFront / 8;	// index of byte in data[] array
		offset = shiftFromFront % 8;; // index of bit in byte to set
		mask = (0b10000000) >> offset;
		bit = data[ind] & mask;

		if (bit) {
			return 1;
		} else {
			return 0;
		}
		// returns 0 or 1 depending on what the bit was. Returns -1 if getting the bit failed
	}

	// Converts the neighbor list from the unordered format in "uint16_t neighbors []" to the Link State Packet format, and writes the LSP at memory address "writeTo"
	int writeLinkStatePack (uint8_t * writeTo) {
		int i;
		//dbg (GENERAL_CHANNEL, "address of writeTo is: %p\n", writeTo);
		//writes the Link State packet in bit format from the neighbors array format (like an array used as a stack)

		// initialize LSP to all 0's
		for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++) {
			writeTo[i] = 0;
		}

		// read the uint16_t neighbors [50] array and write it to the LSP
		for (i = 0; i < top; i++) {
			// Sets the bit in writeTo, that corresponds to the NodeID of the neighbor, to 1.
			// So if the node has 3 neighbors with node ID's of 1, 3, 5, 10 and 11 then the LSP will be:
			//0101010000110000000...padded 0's....(20bytes in packet * 8bits/byte = 160 bits in LSP payload)
			//leftmost bit   corresponds to whether or not the node with and ID of 0 is a neighbor.
			//next bit right corresponds to whether or not the node with and ID of 1 is a neighbor.
			//next bit right corresponds to whether or not the node with and ID of 2 is a neighbor.
			//and so on... to the 160th bit, which corresponds to whether or not the node with an ID of 159 is a neighbor
			//The limitation of this system is that the LSP payload can only deal with node ID's from 0 to 159 (inclusive). 0 <= nodeID <= 159

			// sets a bit in writeTo[], at the position if the node ID (from neighbors[i]), to 1 to indicate that the neighbor is included
			setBit(writeTo, neighbors[i], 1);
		}


	}

	int readLinkStatePack (uint8_t * arrayTo, uint8_t * payloadFrom) {	// reads the Link State Packet from the bit format to the array format (like a row in the routing table)
		int i;
		dbg (ROUTING_CHANNEL, "Reading LSP:\n");
		for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE * 8; i++) {	// This should run once for each bit in the Link State Packet payload array
			if (getBit(payloadFrom, i) == 1) {
				arrayTo[i] = 1;
			} else {
				arrayTo[i] = 0;
			}
		}

		// return value just indicates whether it reached the end of the payload (every last bit of all (PACKET_MAX_PAYLOAD_SIZE * 8) bits)
		if (i >= PACKET_MAX_PAYLOAD_SIZE * 8) {
			return 1;
		}
		return 0;


	}



   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    void sendNeighborDiscoverPack() {
		char text [] = "hi neighbors!";	// length is 2 (3 including null char byte '\0' at end)

		//reset the list to empty every time neighbor discovery is called, then re-add them to list when they respond
		top = 0;
	   dbg(NEIGHBOR_CHANNEL, "Discovering Neighbors. Sending packet: ");
	   makePack(&sendPackage, TOS_NODE_ID, TOS_NODE_ID, 1, 6, mySeqNum, text, PACKET_MAX_PAYLOAD_SIZE);
	   logPack(&sendPackage);
	   call Sender.send(sendPackage, AM_BROADCAST_ADDR);	// AM_BROADCAST_ADDR is only used for flooding and neighbor discovery
	   sentPacks[packsSent%50] = (((sendPackage.seq) << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
	   packsSent++;
	   mySeqNum++;
	   // The recieve function will now make a list of everyone who responded to this packet (who forwards it back with TTL=0).
	   // Maybe the neighbors can just send it only back to the source instead of to AM_BROADCAST_ADDR to all?
   }

   void sendLSP () {
		uint8_t data [PACKET_MAX_PAYLOAD_SIZE];
		writeLinkStatePack (data);	// Creates and formats the LSP, and stores it in array "data"
		dbg (ROUTING_CHANNEL, "Sending LSP:\n");
		makePack(&sendPackage, TOS_NODE_ID, 0, 21, PROTOCOL_LINKEDSTATE, mySeqNum, data, PACKET_MAX_PAYLOAD_SIZE);
		logPack(&sendPackage);
		call Sender.send(sendPackage, AM_BROADCAST_ADDR);	// AM_BROADCAST_ADDR is only used for flooding and neighbor discovery
		sentPacks[packsSent%50] = (((sendPackage.seq) << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
		packsSent++;
		mySeqNum++;
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
	   //call Sender.send(sendPackage, AM_BROADCAST_ADDR);	// AM_BROADCAST_ADDR is only used for flooding and neighbor discovery
	   call Sender.send(sendPackage, forwardingTableNext[to]);	// This is how to forward it only to nextHop
	   sentPacks[packsSent%50] = ((sendPackage.seq << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
	   packsSent++;
	   mySeqNum++;

   }



   void updateForwardingTable()
  {
    //   http://www.eecs.yorku.ca/course_archive/2006-07/W/2011/Notes/BFS_part2.pdf

     /*
     Requirements
     1. Adjacency list
     2. Visited Table (T/F)
     3. Previous list
     */



     uint16_t v;
     uint16_t source_index;
     uint16_t nextHop;
     int i;
     int j;
     int saveJ;



     int r;
     int t;


         // Array to hold previous values so the path can be traced
         uint16_t prev[11];



         // Arrays to hold visited nodes and their boolean values
         uint16_t visited_node[11];
         bool visited_bool[11];
         uint16_t testList[11][11];


         for(i = 0; i <= 10; i++)
           {
             prev[i] = -1;
             visited_bool[i] = FALSE;
             visited_node[i] = 0;

           }


     for(r = 0; r <= 10; r++)
     {
       for(t = 0; t <= 10; t++)
       {
         testList[r][t] = 0;
       }
     }

     testList[1][9] = 1;

     testList[2][3] = 1;
     testList[2][4] = 1;
     testList[2][8] = 1;
     testList[2][10] = 1;

     testList[3][2] = 1;
     testList[3][5] = 1;
     testList[3][9] = 1;

     testList[4][2] = 1;
     testList[4][5] = 1;
     testList[4][6] = 1;

     testList[5][3] = 1;
     testList[5][4] = 1;

     testList[6][4] = 1;
     testList[6][7] = 1;

     testList[7][6] = 1;
     testList[7][8] = 1;

     testList[8][2] = 1;
     testList[8][7] = 1;

     testList[9][1] = 1;
     testList[9][10] = 1;
     testList[9][3] = 1;

     testList[10][2] = 1;
     testList[10][9] = 1;





     // node 1 | TRUE
     // node 2 | FALSE
     // ...


    // initialize all visited table values to FALSE

    for(i = 0; i <= 10; i++)
    {
      visited_bool[i] = FALSE;
    }

    // initialize all prev table values to -1 since no nodes have been visited yet
    for(i = 0; i <= 10; i++)
    {
      prev[i] = -1;
    }


       // Begin algorithm
       //-----------------------------------------------------------------------------------

       // Empty queue First
       while(!(call q.empty()))
       {
         call q.dequeue();
       }

       // index for source node from visited table, already visited source

       source_index = 3 ;
       visited_bool[source_index] = TRUE;

       call q.enqueue(3);


       dbg(GENERAL_CHANNEL, "BEFORE WHILE");

         while(!(call q.empty()))
         {

           v = call q.dequeue();
           dbg(GENERAL_CHANNEL, "IN WHILE");

           for(i = 0; i <= 10; i++)
             {

               /* ERROR RECHECK: if(routing.neighborArray[i][TOS_NODE_ID] == 1)*/
               if(testList[i][v] == 1)
                 {
                     if(visited_bool[i] == FALSE)
                     {
                       visited_bool[i] = TRUE;
                       prev[i] = v;





                       /*dbg(ROUTING_CHANNEL, "Prev[8] = %hhu\n", prev[8] );*/


                       call q.enqueue(i);
                     }
                 }
             }
         }


   // Now our prev array should be complete, we need to traverse this array in order to find the shortest path and the next hop
   // prev[w] = v, w comes after v



   /*dbg(ROUTING_CHANNEL, "Prev[0] = %hhu\n", prev[9] );*/



   // Algorithm complete, now find forwarding table next values


   /*for(i = 0; i < 10; i++)
   {
   dbg(ROUTING_CHANNEL, "Prev[%d] == %hhu\n", i, prev[i] );

   }*/


    for(i = 0; i <= 10; i++)
    {
      dbg(ROUTING_CHANNEL, "Prev[%d] == %hhu\n", i, prev[i] );

    }



   for(i = 1; i <= 10; i++)
   {
   j = i;
   if(j == 3)
     j++;

   while(prev[j] != 3 && prev[j] != 255)
   {

     /*dbg(ROUTING_CHANNEL, "Prev[%d] == %hhu\n", j+1, prev[j-1] );*/
     j = prev[j];
     //nextHop = prev[j];
   } // this loop only ends when prev[j] == 2, so j is the next hop
   nextHop = j;
   /*dbg (ROUTING_CHANNEL, "Next Hop to get to %hhu is %hhu\n", i, nextHop);*/


   forwardingTableTo[i] = i;
   forwardingTableNext[i] = nextHop;

   }

   forwardingTableNext[3] = 3;

   for(i = 1; i <= 10; i++)
   {
   dbg(ROUTING_CHANNEL, "To Node: [%hhu]   |   %hhu\n", forwardingTableTo[i], forwardingTableNext[i] );

   }

  }







   event void Boot.booted(){
	  int i;
	  int j;
	routingTableNumNodes = 0;
    // whitespace
    updateForwardingTable();

      call AMControl.start();
	  call periodicTimer.startPeriodic(200000);
	  //call periodicTimer.fired();
	  //sendNeighborDiscoverPack();
	  for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE * 8; i++) {
		  for (j = 0; j < PACKET_MAX_PAYLOAD_SIZE * 8; j++) {
			  routingTableNeighborArray [i][j] = 0;
		  }
	  }
	  routingTableNumNodes = 0;
	  call randomTimer.startOneShot((call Random.rand32())%200);	// immediately discover neighbors after random time

      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void periodicTimer.fired() {
	   //printNeighbors ();
	   call randomTimer.startOneShot((call Random.rand32())%200);

	   routingTableNumNodes = 0;
   }

   event void randomTimer.fired() {
		// Should the LSP's be send first? Or the Neighbor discovery?
		sendNeighborDiscoverPack();
		sendLSP();

    updateForwardingTable();

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

			 // if it is a link state packet, then update forwarding table
			 if (myMsg->protocol == PROTOCOL_LINKEDSTATE) {

				 if (myMsg->src == TOS_NODE_ID) {
					 dbg (ROUTING_CHANNEL, "Recieved my own LSP\n");
					 return msg;
				 }

				 //uint8_t * routingTableRow;
				 //arr [PACKET_MAX_PAYLOAD_SIZE * 8];
				 dbg (ROUTING_CHANNEL, "Recieved someone else's linkState packet!!!\n");
				 // copy the myMsg->src's neighbor list from payload to the myMsg->src's row in routingTableNeighborArray
				 //readLinkStatePack (uint8_t * arrayTo, uint8_t * payloadFrom)
				 readLinkStatePack (&(routingTableNeighborArray[myMsg->src - 1][0]), (uint8_t *)(myMsg->payload));
				 routingTableNumNodes++;

				 // Forward and keep flooding the Link State Packet
				 call Sender.send(*myMsg, AM_BROADCAST_ADDR);
				 sentPacks[packsSent%50] = ((myMsg->seq << 16) | myMsg->src);	// keep track of all packs send so as not to send them twice
				 packsSent++;
				 //memccpy(routingTablerow, arr, PACKET_MAX_PAYLOAD_SIZE * 8);
				 //return msg;
			 } else {
				 dbg (ROUTING_CHANNEL, "It's not for me. forwarding it on\n");
				 call Sender.send(*myMsg, forwardingTableNext[myMsg->dest]);
			 }



			 //**************************************************************8
			 // Should this store an array of last "top" (number of neighbors) amount of packets stored, to tell when one of them was sent back to previous node again????? That way packets won't go back and forth?????
			 //call Sender.send(*myMsg, AM_BROADCAST_ADDR);	// AM_BROADCAST_ADDR is only used for neighbor discovery and link state packets

			 sentPacks[packsSent%50] = ((myMsg->seq << 16) | myMsg->src);	// keep track of all packs send so as not to send them twice
			 packsSent++;
		 } else if (myMsg->TTL <= 0) {
			 dbg (ROUTING_CHANNEL, "I recieved a packet with no more time to live. Dropping packet\n");
		 } else if (myMsg->src == TOS_NODE_ID) {
			 dbg (ROUTING_CHANNEL, "I recieved my own packet\n");
		 }

         return msg;
      }
      dbg(ROUTING_CHANNEL, "Unknown Packet Type %d\n", len);



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
      //call Sender.send(sendPackage, AM_BROADCAST_ADDR); // AM_BROADCAST_ADDR is only used for neighbor discovery and Link State Packets
	  call Sender.send(sendPackage, forwardingTableNext[destination]);
	  mySeqNum++;
	  packsSent++;
   }

   event void CommandHandler.printNeighbors(){
	   printNeighbors ();
   }

   event void CommandHandler.printRouteTable(){
		int i;
		int j;
		dbg (ROUTING_CHANNEL, "Current Routing Table: routingTableNumNodes = %hhu\n", routingTableNumNodes);
		/*
		uint8_t routingTableNeighborArray[PACKET_MAX_PAYLOAD_SIZE * 8][PACKET_MAX_PAYLOAD_SIZE * 8];
		uint16_t routingTableNumNodes;
		*/

		for (i = 0; i < 50/*PACKET_MAX_PAYLOAD_SIZE * 8*/; i++) {
			for (j = 0; j < 50/*PACKET_MAX_PAYLOAD_SIZE * 8*/; j++) {
				dbg (ROUTING_CHANNEL, "%hhu", routingTableNeighborArray[i][j]);
			}
			dbg (ROUTING_CHANNEL, "\n");
		}

		dbg (ROUTING_CHANNEL, "Current Forwarding Table: forwardingTableNumNodes = %hhu\n", forwardingTableNumNodes);
		for (i = 0; i < forwardingTableNumNodes; i++) {
			dbg (ROUTING_CHANNEL, "forwardingTableTo = %hhu, forwardingTableNext = %hhu\n", forwardingTableTo[i], forwardingTableNext[i]);
		}

   }

   event void CommandHandler.printLinkState(){
	   dbg (ROUTING_CHANNEL, "Link State Packet:\n");
   }

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
