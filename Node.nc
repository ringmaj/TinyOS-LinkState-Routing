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
   uses interface Timer<TMilli> as constantTimer;
   uses interface Timer<TMilli> as LSPTimer;
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
			dbg (GENERAL_CHANNEL, "setBit error: setBit can only set a bit to 0 or 1\n");
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
			setBit(writeTo, neighbors[i] - 1, 1);
		}


	}

	int readLinkStatePack (uint8_t * arrayTo, uint8_t * payloadFrom) {	// reads the Link State Packet from the bit format to the array format (like a row in the routing table)
		int i;
		dbg (ROUTING_CHANNEL, "Copying LSP from payload into array\n");
		for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE * 8; i++) {	// This should run once for each bit in the Link State Packet payload array
			if (getBit(payloadFrom, i) == 1) {
				arrayTo[i] = 1;
			} else {
				//arrayTo[i] = 0;
        // overwrites unidirectional routing
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

   void printLSP (uint8_t* data, char channel []) {
		//int i;
		//uint8_t arr [PACKET_MAX_PAYLOAD_SIZE];
		//for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE; i++) {
		//	arr[i] = data[i];
		//}
		dbg (channel, "0x%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X\n", data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7], data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15], data[16], data[17], data[18], data[19]);
		//dbg (ROUTING_CHANNEL, "%d", getBit(data, 0));

   }

   void sendLSP () {
		uint8_t data [PACKET_MAX_PAYLOAD_SIZE];
		writeLinkStatePack (data);	// Creates and formats the LSP, and stores it in array "data"
		dbg (ROUTING_CHANNEL, "Sending LSP:\n");
		makePack(&sendPackage, TOS_NODE_ID, 0, 21, PROTOCOL_LINKEDSTATE, mySeqNum, data, PACKET_MAX_PAYLOAD_SIZE);
		//logPack(&sendPackage);
		dbg(GENERAL_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol: %hhu  Payload:\n", sendPackage.src, sendPackage.dest, sendPackage.seq, sendPackage.TTL, sendPackage.protocol);

		// is this an incompatible pointer type???????????
		printLSP(sendPackage.payload, GENERAL_CHANNEL);

		// Update my own Routing table with my own LSP
		readLinkStatePack (&(routingTableNeighborArray[sendPackage.src - 1][0]), (uint8_t *)(sendPackage.payload));
		routingTableNumNodes++;

		call Sender.send(sendPackage, AM_BROADCAST_ADDR);	// AM_BROADCAST_ADDR is only used for flooding and neighbor discovery
		sentPacks[packsSent%50] = (((sendPackage.seq) << 16) | sendPackage.src);	// keep track of all packs send so as not to send them twice
		packsSent++;
		mySeqNum++;
   }


   void printNeighbors (char channel []) {
	   int i;
	   dbg (channel, "My %hhu neighbor(s) are:\n", top);

	   for (i = 0; i < top; i++) {
		   dbg (channel, "%hhu\n", neighbors[i]);
	   }

     dbg(channel, "\n");
     dbg(channel, "\n");

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

   void logPack_command(pack *input){
   	dbg(COMMAND_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol:%hhu  Payload: %s\n",
   	input->src, input->dest, input->seq, input->TTL, input->protocol, input->payload);
   }


   void updateForwardingTable(int size)
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

         // Array to hold previous values so the path can be traced
         uint16_t prev[size];

         // Arrays to hold visited nodes and their boolean values
         bool visited_bool[size+1];
         uint16_t testList[size+1][size+1];


         for(i = 0; i <= size; i++)
           {
             prev[i] = -1;
             visited_bool[i] = FALSE;
           }



    // initialize all visited table values to FALSE

    for(i = 0; i <= size; i++)
    {
      visited_bool[i] = FALSE;
    }

    // initialize all prev table values to -1 since no nodes have been visited yet
    for(i = 0; i <= size; i++)
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

       source_index = TOS_NODE_ID ;
       visited_bool[source_index] = TRUE;

       call q.enqueue(TOS_NODE_ID);
         while(!(call q.empty()))
         {
           v = call q.dequeue();
           for(i = 1; i <= size; i++)
             {
               if(routingTableNeighborArray[v-1][i-1] == 1)
                 {
                     if(visited_bool[i] == FALSE)
                     {
                       visited_bool[i] = TRUE;
                       prev[i] = v;
                       call q.enqueue(i);
                     }
                 }
             }
         }


   // Algorithm complete, now find forwarding table next values
   // Now our prev array should be complete, we need to traverse this array in order to find the shortest path and the next hop
   // prev[w] = v, w comes after v


   dbg(ROUTING_CHANNEL, "Node: %hhu's PREV table: \n",  TOS_NODE_ID );

    for(i = 0; i <= size; i++)
    {
      dbg(ROUTING_CHANNEL, "Prev[%d] == %hhu\n", i, prev[i] );

    }

   for(i = 1; i <= size; i++)
   {
     j = i;

     // this loop only ends when prev[j] == 2, so j is the next hop
     while(prev[j] != TOS_NODE_ID && prev[j] < 160)
     {
       j = prev[j];

     }
     nextHop = j;
     forwardingTableTo[i] = i;
     if(prev[j] < 160)
      forwardingTableNext[i] = nextHop;
   }

   forwardingTableNext[TOS_NODE_ID] = TOS_NODE_ID;

   dbg(ROUTING_CHANNEL, "Node: %hhu's Forwarding table: \n",  TOS_NODE_ID );

   // Print forwarding table
   for(i = 1; i <= size; i++)
   {
   dbg(ROUTING_CHANNEL, "To Node: [%hhu]   |   %hhu\n", forwardingTableTo[i], forwardingTableNext[i] );

   }

   }



   void printRoutingTable(char channel []) {
   	int i;
   	int j;



	/*dbg (COMMAND_CHANNEL, "void printRoutingTable(char channel [])  is printing from channel: %s\n", channel);

   	dbg (COMMAND_CHANNEL, "Current Routing Table: routingTableNumNodes = %hhu\n", routingTableNumNodes);
*/


       i = 1;
       dbg (channel, "   %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d  %d\n", i, i+1, i+2, i+3, i+4, i+5, i+6, i+7, i+8,i+9,i+10,i+11,i+12,i+13,i+14,i+15,i+16,i+17,i+18);
       /*dbg (channel, "   %d  %d  %d  %d  %d  %d  %d  %d  %d\n", i, i+1, i+2, i+3, i+4, i+5, i+6, i+7, i+8);*/

       for (i = 0; i < 19/*PACKET_MAX_PAYLOAD_SIZE * 8*/; i++) {
         j = 0;

         if(i >= 9) {
       //printf("%d %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10], routingTableNeighborArray[i][11], routingTableNeighborArray[i][12], routingTableNeighborArray[i][13], routingTableNeighborArray[i][14], routingTableNeighborArray[i][15], routingTableNeighborArray[i][16], routingTableNeighborArray[i][17], routingTableNeighborArray[i][18], routingTableNeighborArray[i][19]);
       dbg (channel, "%d %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu   %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu   %hhu   %hhu   %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10],routingTableNeighborArray[i][11],routingTableNeighborArray[i][12],routingTableNeighborArray[i][13],routingTableNeighborArray[i][14],routingTableNeighborArray[i][15],routingTableNeighborArray[i][16],routingTableNeighborArray[i][17],routingTableNeighborArray[i][18],routingTableNeighborArray[i][19],routingTableNeighborArray[i][20]);

     } else {
       //printf("%d  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10], routingTableNeighborArray[i][11], routingTableNeighborArray[i][12], routingTableNeighborArray[i][13], routingTableNeighborArray[i][14], routingTableNeighborArray[i][15], routingTableNeighborArray[i][16], routingTableNeighborArray[i][17], routingTableNeighborArray[i][18], routingTableNeighborArray[i][19]);
       dbg (channel, "%d  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu   %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu   %hhu   %hhu   %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10],routingTableNeighborArray[i][11],routingTableNeighborArray[i][12],routingTableNeighborArray[i][13],routingTableNeighborArray[i][14],routingTableNeighborArray[i][15],routingTableNeighborArray[i][16],routingTableNeighborArray[i][17],routingTableNeighborArray[i][18],routingTableNeighborArray[i][19],routingTableNeighborArray[i][20]);

     }



   	//for (i = 0; i < 19/*PACKET_MAX_PAYLOAD_SIZE * 8*/; i++) {
   	//	j = 0;

    //   if(i >= 9) {
			//printf("%d %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10], routingTableNeighborArray[i][11], routingTableNeighborArray[i][12], routingTableNeighborArray[i][13], routingTableNeighborArray[i][14], routingTableNeighborArray[i][15], routingTableNeighborArray[i][16], routingTableNeighborArray[i][17], routingTableNeighborArray[i][18], routingTableNeighborArray[i][19]);
			//dbg (channel, "%d %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10]);

		//} else {
			//printf("%d  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10], routingTableNeighborArray[i][11], routingTableNeighborArray[i][12], routingTableNeighborArray[i][13], routingTableNeighborArray[i][14], routingTableNeighborArray[i][15], routingTableNeighborArray[i][16], routingTableNeighborArray[i][17], routingTableNeighborArray[i][18], routingTableNeighborArray[i][19]);
		//	dbg (channel, "%d  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu  %hhu\n", i+1, routingTableNeighborArray[i][0], routingTableNeighborArray[i][1], routingTableNeighborArray[i][2], routingTableNeighborArray[i][3], routingTableNeighborArray[i][4], routingTableNeighborArray[i][5], routingTableNeighborArray[i][6], routingTableNeighborArray[i][7], routingTableNeighborArray[i][8], routingTableNeighborArray[i][9], routingTableNeighborArray[i][10]);

		//}


   		/*
   		for (j = 0; j < PACKET_MAX_PAYLOAD_SIZE * 8; j++) {
   			dbg (channel, "%hhu", routingTableNeighborArray[i][j]);
   		}
   		*/
   	}

    dbg (channel, "\n");
    dbg (channel, "\n");

   	dbg (channel, "Current Forwarding Table:\n");

   	for (i = 1; i <= 19; i++) {
   		dbg (channel, "To: %hhu, Next: %hhu\n", forwardingTableTo[i], forwardingTableNext[i]);
   	}
   }




event void Boot.booted(){
	  int i;
	  int j;
	  routingTableNumNodes = 0;
      call AMControl.start();
	  call periodicTimer.startPeriodic(200000);
	  for (i = 0; i < PACKET_MAX_PAYLOAD_SIZE * 8; i++) {
		  for (j = 0; j < PACKET_MAX_PAYLOAD_SIZE * 8; j++) {
			  routingTableNeighborArray [i][j] = 0;
		  }
	  }
	  //printRoutingTable (COMMAND_CHANNEL);
	  call randomTimer.startOneShot((call Random.rand32())%400);	// immediately discover neighbors after random time, on start. So don't need to wait for 1st period.
	  call LSPTimer.startOneShot(800 + ((call Random.rand32()) % 400));
	  call constantTimer.startOneShot(2000);
   }

	// neighbor discovery is required to put the neigbors in the LSP, and send the neighbor list.
	// recieving the LSP's is required to build the routing table, to understand the topology and do Dijkstra's and find shortest path
	// Doing Dijkstra's and finding shortest path is required to build the forwarding table
	// Having the forwarding table is required to send packets

	// So we need a timeline to ensure everything happens in order. And we need to ensure that sending is done at random times (in certain windows of time). To prevent signal collision and ensure transmission arrives on time

	// Timeline of 1 period (beginning at Boot.booted(), or periodicTimer.fired())
	//[t = 0 milliseconds, Boot.booted called or periodicTimer.fired() called]
	//[0 <= t < 200, neighbor discovery packets sent early, so ]
	//[200 <= t < 400, wait for neighbor discovery packets to arrive, so we know what neighbors we have when we send LSP's]
	//[400 <= t < 600, send LSP's, using neighbor list from neighbor packets that arrived]
	//[600 <= t < 1000, wait for all LSP's to flood network arrive so we know what network topology looks like before updating forwarding table]
	//[t == 1000, update forwarding table]
	//[t == 200000, timer resets, so t = 0 milliseconds]

   event void periodicTimer.fired() {
	   call randomTimer.startOneShot((call Random.rand32())%400);
	   call LSPTimer.startOneShot(800 + ((call Random.rand32()) % 400));
	   call constantTimer.startOneShot(2000);
   }

   event void randomTimer.fired() {
		// Should the LSP's be send first? Or the Neighbor discovery?
		sendNeighborDiscoverPack();
		// pause to let the neighbor discovery packets return
		//call LSPTimer.startOneShot(600);
		//sendLSP();
		// pause to let the neighbor discovery packets return

   }

   event void constantTimer.fired() {
	   updateForwardingTable(19);
	  // printRoutingTable(ROUTING_CHANNEL);

	   routingTableNumNodes = 0;
   }

   event void LSPTimer.fired () {
	   sendLSP();
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
	  //bool found;
      //dbg(GENERAL_CHANNEL, "\nPacket Received: ");


      if(len==sizeof(pack)){
         pack* myMsg=(pack*) payload;
		 //logPack (myMsg);		// just prints out package's info & payload
		 if (myMsg->dest == TOS_NODE_ID) {

			 //char text [] = "hi";	//"All neighbors, please reply";	// length is 27 (28 including null char byte '\0' at end)	// Network Discovery message
			 if (myMsg->TTL == 0 && myMsg->protocol == 6 && myMsg->src != TOS_NODE_ID/*&& strncmp(text, payload, 2) == 0*/) {	// Should this also check if a network discovery packet has been sent recently???

				 // record the neighbor (this packet's sender)
				 // If this neighbor is not in neighborArray, then add it to neighborArray
				 //found = FALSE;
				 /*for (i = 0; i < top; i++) {
					 if (neighbors[i] == myMsg->src) {
						 break;
					 }
				 }
				 if (i >= top) {
					 // record the neighbor (this packet's sender)
					 neighbors [top] = myMsg->src;
					 top++;
				 }*/
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

				 dbg (COMMAND_CHANNEL, "The message is for me!\n");
				 logPack (myMsg);
         logPack_command (myMsg);
				 // send reply
				 reply(myMsg->src);


			 }

		 } else if (myMsg->TTL > 0 && myMsg->src != TOS_NODE_ID) {	// should also check that this packet wasn't already forwarded by this node (store a list of packets already forwarded in a hashmap or a list)
			 myMsg->TTL --;	// will decrementing TTL and incrementing seq this way work? Or do I have to make a new packet?

			 // check if it's another node's network discovery packet
			 if (myMsg->src == myMsg->dest) {	// if source == destination, then it's a network discovery packet



				 // If this neighbor is not in neighborArray, then add it to neighborArray

				 /*for (i = 0; i < top; i++) {
					 if (neighbors[i] == myMsg->src) {
						 break;
					 }
				 }
				 //dbg (NEIGHBOR_CHANNEL, "This line means that the new code is being added. i = %d. top = %hhu\n", i, top);
				 if (i >= top) {
					 // record the neighbor (this packet's sender)
					 neighbors [top] = myMsg->src;
					 top++;
					 //dbg (NEIGHBOR_CHANNEL, "Top: %hhu\n", top);
				 }*/

         /*neighbors [top] = myMsg->src;
         top++;*/

				 dbg (NEIGHBOR_CHANNEL, "Recieved %hhu's neighbor discovery packet. Sending it back to them. I now have %hhu neighbors\n", myMsg->src, top);
				 if (i >= top) {
					 dbg (NEIGHBOR_CHANNEL, "Node %hhu is now discovered\n", myMsg->src);
				 }

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
					 dbg(ROUTING_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol: %hhu  Payload:\n", myMsg->src, myMsg->dest, myMsg->seq, myMsg->TTL, myMsg->protocol);
					 printLSP(myMsg->payload, ROUTING_CHANNEL);
					 return msg;
				 }



				 //uint8_t * routingTableRow;
				 //arr [PACKET_MAX_PAYLOAD_SIZE * 8];
				 dbg (ROUTING_CHANNEL, "Recieved %hhu's linkState packet!!!\n", myMsg->src);
				 dbg(ROUTING_CHANNEL, "Src: %hhu Dest: %hhu Seq: %hhu TTL: %hhu Protocol: %hhu  Payload:\n", myMsg->src, myMsg->dest, myMsg->seq, myMsg->TTL, myMsg->protocol);
				 printLSP(myMsg->payload, ROUTING_CHANNEL);

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

    printRoutingTable(COMMAND_CHANNEL);
	  mySeqNum++;
	  packsSent++;
   }

   event void CommandHandler.printNeighbors(){
	   printNeighbors (COMMAND_CHANNEL);
   }

   event void CommandHandler.printRouteTable(){
		printRoutingTable(COMMAND_CHANNEL);
		//printRoutingTable (COMMAND_CHANNEL);
		//dbg (COMMAND_CHANNEL, "Command Handler has printed routing table on command channel?\n");
   }

   event void CommandHandler.printLinkState(){
	   uint8_t dummyLSP [PACKET_MAX_PAYLOAD_SIZE];
	   dbg (ROUTING_CHANNEL, "Link State Packet:\n");
	   writeLinkStatePack (dummyLSP);
	   printLSP(dummyLSP, COMMAND_CHANNEL);
	   dbg (COMMAND_CHANNEL, "Source: %hhu\n", TOS_NODE_ID);
	   printNeighbors (COMMAND_CHANNEL);

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
